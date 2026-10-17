//! `polter +launch <role> [<cli>] [--group=<name>] [--resume=<session>]
//! [-- <arg>...]` -- become an agent CLI wearing a role.
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
//! Anything after a `--` goes to the CLI as written, after the role's own
//! extra arguments: `polter +launch polter-supervisor claude-code -- -r`.
//! It travels in the launch request's `args` like those, so the adapter
//! treats it the same way (Claude Code's merges a `--settings <json>` into
//! its own and appends the rest to the command line).
//!
//! Two words are Polter's own and go before the `--`, and both are only
//! ever typed by the control room starting a group's supervisor
//! (`App.controlActStartSupervisor`):
//!
//!   * `--group=<name>` -- the group this supervisor is being started for.
//!     It changes one thing: what the agent is told at launch
//!     (`persona.launchInstructions`) names the group and tells it to read
//!     that group rather than make one.
//!   * `--resume=<session>` -- the session to go on with, as the CLI named
//!     it through its hooks last time. It goes to the adapter in the
//!     launch request's `session`, not onto the command line: how a CLI is
//!     told to go on with a session is the adapter's to know. An adapter
//!     that finds the session gone starts a new one and says so in a note,
//!     which is printed here before the CLI takes the screen.
//!
//! Both are held to a few plain characters (`Chat.isValidName`,
//! `agent_cli.isSessionToken`), which is what lets the line be typed into a
//! shell with nothing in it to quote.
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
const official = @import("../poltergeist/official.zig");
const agent_cli = @import("../poltergeist/agent_cli.zig");
const Plugin = @import("../poltergeist/Plugin.zig");
const AgentEvent = @import("../poltergeist/agent_event.zig");
const hook = @import("hook.zig");
const Chat = @import("../poltergeist/Chat.zig");

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
///   polter +launch <role> [<cli>] [--group=<name>] [--resume=<session>] [-- <arg>...]
///
/// `<role>` is the role's key. `<cli>` is the key of the plugin that
/// manages the CLI (`claude-code`), and may be left out when the role is
/// set up for exactly one.
///
/// Everything after `--` is handed to the CLI as written, after the role's
/// own extra arguments, e.g. `polter +launch dev-worker claude-code -- -r`.
///
/// `--group=<name>` says which group a supervisor is being started for,
/// and `--resume=<session>` asks the CLI's adapter to go on with that
/// session; the control room types both.
///
/// Normally this is not typed by hand: "Launch with Role" in a tab's menu,
/// and the supervisor's `role_launch`, open a terminal and type it there.
pub fn run(alloc: Allocator) !u8 {
    const io = global.io();

    // **A launch that starts nothing says so to this terminal's Polter**,
    // which may be waiting on an agent from here: a role's standing is
    // held for it, and the control room may be showing "starting the
    // supervisor" for it. The line on the screen says why to whoever
    // looks at the tab; this says it to what cannot look.
    var progress: Progress = .{};
    const code = start(alloc, &progress) catch |err| {
        if (!progress.started) reportFailed(io, &progress);
        return err;
    };
    if (!progress.started) reportFailed(io, &progress);
    return code;
}

/// How far a launch got, for what is said when it gets no further.
const Progress = struct {
    /// The CLI is running (or, where there is no `exec`, was started): what
    /// this process returns from here on is the CLI's doing, not a launch
    /// that failed. **Set only once the system has started it**; a CLI that
    /// starts and exits at once is not a launch that failed -- a real one
    /// may leave straight away for reasons of its own (`--version`, a
    /// sign-in it wants first), and the minute's wait for an agent is what
    /// answers for that.
    started: bool = false,
    why: AgentEvent.LaunchFailure = .failed,
    /// The CLI's key, once it is known which one.
    cli: [64]u8 = undefined,
    cli_len: usize = 0,

    fn noteCli(self: *Progress, key: []const u8) void {
        const n = @min(key.len, self.cli.len);
        @memcpy(self.cli[0..n], key[0..n]);
        self.cli_len = n;
    }
};

fn start(alloc: Allocator, progress: *Progress) !u8 {
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

    const parsed = parseArgs(aa) catch |err| {
        try err_out.writeAll(switch (err) {
            error.ExtraArgument => "Polter: `+launch` takes a role and a CLI; " ++
                "put what is for the CLI after `--`.\n",
            error.BadGroup => "Polter: `--group=` needs a group's name.\n",
            error.BadSession => "Polter: `--resume=` needs a session's id, " ++
                "in letters, digits, `.`, `_` and `-`.\n",
            else => "Polter: `+launch` needs a role.\n",
        });
        try err_out.writeAll(usage);
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
    // The official roles with what the person changed in them, read the
    // way the app reads them: this is another process, and it must not
    // start a different role from the one the library window shows.
    const set = official.assemble(
        aa,
        bytes,
        &official.sources,
        PersonaStore.readOverrides(aa, io, path),
    ) catch |err| {
        try err_out.print("Polter: {s} does not read as a role library ({t}).\n", .{ path, err });
        return 1;
    };
    var p = set.find(parsed.role) orelse {
        try err_out.print("Polter: there is no role called \"{s}\".\n", .{parsed.role});
        return 1;
    };
    // A supervisor role's agent is told it is one, and of which group when
    // it was started for one (`persona.launchInstructions`).
    p.instructions = try persona.launchInstructions(aa, p, parsed.group);

    // --- which CLI
    var env = try global.environMap();
    defer env.deinit();
    const adapters = agent_cli.discover(aa, io, &env);

    // Named, or the role's default by the app's own rule
    // (`Persona.defaultCli`): of the CLIs it is set up for, the only one
    // with an adapter here. The app always names one on the line it types;
    // this is for a person typing `polter +launch <role>`, who is the one
    // asking and has no CLI of their own to go by.
    const choice: persona.CliChoice = if (parsed.cli) |key|
        p.cli(key) orelse {
            try err_out.print(
                "Polter: the role \"{s}\" is not set up for {s}.\n",
                .{ p.name, key },
            );
            return 1;
        }
    else choice: {
        const keys = try aa.alloc([]const u8, adapters.len);
        for (adapters, keys) |a, *k| k.* = a.key;
        const key = p.defaultCli(keys, null) catch |err| switch (err) {
            error.NoCli => {
                try err_out.print(
                    "Polter: the role \"{s}\" is not set up for any agent CLI. " ++
                        "Open the role library and pick one.\n",
                    .{p.name},
                );
                return 1;
            },
            error.ChooseCli => {
                try err_out.print(
                    "Polter: the role \"{s}\" is set up for more than one CLI; say which:\n",
                    .{p.name},
                );
                for (p.clis) |c| try err_out.print("    polter +launch {s} {s}\n", .{ p.key, c.cli });
                return 2;
            },
        };
        break :choice p.cli(key).?;
    };

    // --- the adapter
    progress.noteCli(choice.cli);
    const adapter = agent_cli.find(adapters, choice.cli) orelse {
        try whyNoAdapter(aa, io, &env, choice.cli, err_out);
        return 1;
    };

    const cwd = std.process.currentPathAlloc(io, aa) catch null;
    var request: std.Io.Writer.Allocating = .init(aa);
    try agent_cli.writeLaunchRequest(
        &request.writer,
        p,
        try withPassthrough(aa, choice, parsed.passthrough),
        cwd,
        env.get("HOME") orelse env.get("USERPROFILE"),
        mcpExecutable(aa, io),
        parsed.session,
    );

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

    // The adapter put hooks in the CLI's settings: tell this terminal's
    // Polter to expect them, so that hearing nothing from them for long
    // enough is reported as a fault rather than read as nothing happening
    // (adapters.md 3.4). Before the CLI starts, so its `session_started`
    // cannot arrive first. Best effort, like `+hook` itself: a launch is
    // not refused because Polter could not be told.
    if (launch.hooks) expectHooks(io, &env, adapter.key, launch.hooks_heard);

    if (comptime std.process.can_replace) {
        const err = std.process.replace(io, .{ .argv = launch.argv, .environ_map = &env });
        // It only comes back when the CLI was not started.
        if (err == error.FileNotFound) progress.why = .not_found;
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
        if (err == error.FileNotFound) progress.why = .not_found;
        try err_out.print("Polter: could not start {s} ({t}).", .{ launch.argv[0], err });
        if (err == error.FileNotFound) try err_out.print(" Is {s} installed?", .{adapter.bin});
        try err_out.writeAll("\n");
        return 127;
    };
    // The system started it. Whatever it exits with from here is its own.
    progress.started = true;
    const term = child.wait(io) catch |err| {
        try err_out.print("Polter: lost track of {s} ({t}).\n", .{ launch.argv[0], err });
        return 1;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// The executable provisioning registers for `+mcp`, which is also what a
/// CLI's hooks run as `+hook` (adapters.md 3.2). Null when it cannot be
/// found, and the adapter then configures no hooks and says so.
///
/// On POSIX that is this very program: the launch line is typed with the
/// app's own path (`App.launchLine`). On Windows it is not -- `+launch` runs
/// as `polter-cli.exe`, and `+mcp` is registered as `polter-host.exe`
/// beside it (`windows/host/src/main.rs`, `cli_sibling`), which an agent CLI
/// starts with inherited pipes the same way it starts a hook.
fn mcpExecutable(aa: Allocator, io: std.Io) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = buf[0 .. std.process.executablePath(io, &buf) catch return null];
    if (comptime builtin.os.tag != .windows) return aa.dupe(u8, self_exe) catch null;

    const dir = std.fs.path.dirname(self_exe) orelse return null;
    const host = std.fs.path.join(aa, &.{ dir, "polter-host.exe" }) catch return null;
    std.Io.Dir.cwd().access(io, host, .{}) catch return null;
    return host;
}

/// Tell this terminal's Polter the launch started nothing, and which kind
/// of nothing. Best effort, like `expectHooks`: outside Polter there is
/// nobody to tell, and the line on the screen has already said it.
///
/// This also takes back `hooks_expected`, if that was said: no hooks are
/// coming from a CLI that never ran (`Bus.agentEvent`).
fn reportFailed(io: std.Io, progress: *const Progress) void {
    var env = global.environMap() catch return;
    defer env.deinit();
    const socket_path = env.get("GHOSTTY_POLTER_SOCKET") orelse return;
    const token = env.get("GHOSTTY_POLTER_TOKEN") orelse return;
    var ev: AgentEvent.Event = .none;
    ev.event = .launch_failed;
    ev.cli = progress.cli[0..progress.cli_len];
    ev.detail = @tagName(progress.why);
    hook.deliver(io, socket_path, token, ev) catch |err| {
        std.log.scoped(.launch).warn("could not say the launch failed err={t}", .{err});
    };
}

fn expectHooks(
    io: std.Io,
    env: *const std.process.Environ.Map,
    cli: []const u8,
    heard: agent_cli.HooksHeard,
) void {
    const socket_path = env.get("GHOSTTY_POLTER_SOCKET") orelse return;
    const token = env.get("GHOSTTY_POLTER_TOKEN") orelse return;
    var ev: AgentEvent.Event = .none;
    ev.event = .hooks_expected;
    ev.cli = cli;
    ev.detail = AgentEvent.hooksExpectedDetail(heard == .first_turn);
    hook.deliver(io, socket_path, token, ev) catch |err| {
        std.log.scoped(.launch).warn("could not say hooks are expected err={t}", .{err});
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

const usage =
    \\
    \\    polter +launch <role> [<cli>] [--group=<name>] [--resume=<session>] [-- <arg>...]
    \\
;

const Parsed = struct {
    role: []const u8,
    cli: ?[]const u8,
    /// The group a supervisor is being started for; null when none was
    /// named.
    group: ?[]const u8,
    /// The session to go on with; null for a new one.
    session: ?[]const u8,
    /// What came after `--`, for the CLI, in order. Empty without one.
    passthrough: []const []const u8,
};

const ParseError = error{ NoRole, ExtraArgument, BadGroup, BadSession };

/// `<role> [<cli>] [-- <arg>...]` after our own `+launch` token.
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

    var rest: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try rest.append(aa, try aa.dupe(u8, arg));
    return parseRest(rest.items);
}

/// `args` is everything after `+launch`. Returns slices of it.
///
/// A third word before `--` is refused rather than dropped: dropping it
/// is how `+launch dev-worker claude-code -r` used to start a CLI that
/// had never been told `-r`, with nothing on screen to say so.
///
/// `--group=` and `--resume=` are Polter's own and may stand anywhere
/// before the `--`. Each is held to what it can be -- a group's name, a
/// session's id in plain characters -- and refused otherwise rather than
/// passed along: the line is typed into a shell, and the second goes to
/// an adapter that puts it on a command line.
fn parseRest(args: []const []const u8) ParseError!Parsed {
    const split = for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) break i;
    } else args.len;
    const passthrough = if (split < args.len) args[split + 1 ..] else args[args.len..];

    var words: [2][]const u8 = undefined;
    var n: usize = 0;
    var group: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    for (args[0..split]) |a| {
        if (cut(a, "--group=")) |v| {
            if (!Chat.isValidName(v)) return error.BadGroup;
            group = v;
        } else if (cut(a, "--resume=")) |v| {
            if (!agent_cli.isSessionToken(v)) return error.BadSession;
            session = v;
        } else {
            if (n == 0 and !persona.isValidKey(a)) return error.NoRole;
            if (n == words.len) return error.ExtraArgument;
            words[n] = a;
            n += 1;
        }
    }

    if (n == 0) return error.NoRole;
    return .{
        .role = words[0],
        .cli = if (n == 2) words[1] else null,
        .group = group,
        .session = session,
        .passthrough = passthrough,
    };
}

fn cut(arg: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

/// `choice` with `passthrough` after its own `args`: the role's extra
/// arguments first, then what was typed after `--`, so a later flag the
/// person typed wins wherever the CLI lets a repeat override.
fn withPassthrough(
    aa: Allocator,
    choice: persona.CliChoice,
    passthrough: []const []const u8,
) Allocator.Error!persona.CliChoice {
    if (passthrough.len == 0) return choice;
    var out = choice;
    out.args = try std.mem.concat(aa, []const u8, &.{ choice.args, passthrough });
    return out;
}

test "+launch: no `--` is a role and an optional CLI, nothing passed through" {
    const one = try parseRest(&.{"dev-worker"});
    try std.testing.expectEqualStrings("dev-worker", one.role);
    try std.testing.expect(one.cli == null);
    try std.testing.expectEqual(0, one.passthrough.len);

    const two = try parseRest(&.{ "dev-worker", "claude-code" });
    try std.testing.expectEqualStrings("claude-code", two.cli.?);
    try std.testing.expectEqual(0, two.passthrough.len);
}

test "+launch: `--` right after the role leaves the CLI to the role" {
    const p = try parseRest(&.{ "dev-worker", "--", "-r" });
    try std.testing.expectEqualStrings("dev-worker", p.role);
    try std.testing.expect(p.cli == null);
    try std.testing.expectEqual(1, p.passthrough.len);
    try std.testing.expectEqualStrings("-r", p.passthrough[0]);
}

test "+launch: `--` after the CLI passes everything after it, in order" {
    const p = try parseRest(&.{ "dev-worker", "claude-code", "--", "x", "--", "y" });
    try std.testing.expectEqualStrings("claude-code", p.cli.?);
    try std.testing.expectEqual(3, p.passthrough.len);
    try std.testing.expectEqualStrings("x", p.passthrough[0]);
    // A second `--` belongs to the CLI, not to us.
    try std.testing.expectEqualStrings("--", p.passthrough[1]);
    try std.testing.expectEqualStrings("y", p.passthrough[2]);
}

test "+launch: a `--` with nothing after it passes nothing" {
    const p = try parseRest(&.{ "dev-worker", "claude-code", "--" });
    try std.testing.expectEqualStrings("claude-code", p.cli.?);
    try std.testing.expectEqual(0, p.passthrough.len);
}

test "+launch: a third word before `--` is refused, not dropped" {
    try std.testing.expectError(
        error.ExtraArgument,
        parseRest(&.{ "dev-worker", "claude-code", "-r" }),
    );
    try std.testing.expectError(
        error.ExtraArgument,
        parseRest(&.{ "dev-worker", "claude-code", "-r", "--", "x" }),
    );
    try std.testing.expectError(error.NoRole, parseRest(&.{}));
    try std.testing.expectError(error.NoRole, parseRest(&.{ "--", "x" }));
}

test "+launch: the control room's two words are read wherever they stand before `--`, and never as the role or the CLI" {
    const p = try parseRest(&.{ "polter-supervisor", "claude-code", "--group=web-app", "--resume=eed9173b-c1fc-4493-aa00-187bacdc94cf" });
    try std.testing.expectEqualStrings("polter-supervisor", p.role);
    try std.testing.expectEqualStrings("claude-code", p.cli.?);
    try std.testing.expectEqualStrings("web-app", p.group.?);
    try std.testing.expectEqualStrings("eed9173b-c1fc-4493-aa00-187bacdc94cf", p.session.?);
    try std.testing.expectEqual(0, p.passthrough.len);

    // Without a CLI, and in the other order.
    const q = try parseRest(&.{ "--resume=s.1_a", "polter-supervisor", "--group=g" });
    try std.testing.expect(q.cli == null);
    try std.testing.expectEqualStrings("g", q.group.?);
    try std.testing.expectEqualStrings("s.1_a", q.session.?);

    // Neither named is neither known, not an empty one of each.
    const bare = try parseRest(&.{"polter-supervisor"});
    try std.testing.expect(bare.group == null);
    try std.testing.expect(bare.session == null);

    // After the `--` they are the CLI's, as everything there is.
    const past = try parseRest(&.{ "polter-supervisor", "--", "--resume=x" });
    try std.testing.expect(past.session == null);
    try std.testing.expectEqualStrings("--resume=x", past.passthrough[0]);
}

test "+launch: the words the app types are the words this reads back" {
    // The two ends of one line: `App.launchLine` writes it with
    // `agent_cli.writeLaunchWords`, a shell splits it on spaces, and
    // `parseRest` is handed what follows `+launch`.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try agent_cli.writeLaunchWords(&w, "polter-supervisor", "claude-code", .{
        .group = "web-app",
        .session = "eed9173b-c1fc-4493-aa00-187bacdc94cf",
    });

    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, w.buffered(), ' ');
    while (it.next()) |word| : (n += 1) words[n] = word;
    try std.testing.expectEqualStrings("+launch", words[0]);

    const p = try parseRest(words[1..n]);
    try std.testing.expectEqualStrings("polter-supervisor", p.role);
    try std.testing.expectEqualStrings("claude-code", p.cli.?);
    try std.testing.expectEqualStrings("web-app", p.group.?);
    try std.testing.expectEqualStrings("eed9173b-c1fc-4493-aa00-187bacdc94cf", p.session.?);
    try std.testing.expectEqual(0, p.passthrough.len);
}

test "+launch: a group or a session that is not one is refused, not typed on" {
    // What a shell or a command line would read as something else.
    // (`-rf` is a group's name as far as `Chat.isValidName` goes, and after
    // `--group=` it is not an option to anything.)
    for ([_][]const u8{ "", "a b", "a;b", "$(x)", "a'b", "a/b", "Web" }) |bad| {
        var buf: [64]u8 = undefined;
        const g = try std.fmt.bufPrint(&buf, "--group={s}", .{bad});
        try std.testing.expectError(error.BadGroup, parseRest(&.{ "r", g }));
    }
    for ([_][]const u8{ "", "a b", "a;b", "$(x)", "a'b", "-rf", "a/b", "a\"b" }) |bad| {
        var buf: [64]u8 = undefined;
        const r = try std.fmt.bufPrint(&buf, "--resume={s}", .{bad});
        try std.testing.expectError(error.BadSession, parseRest(&.{ "r", r }));
    }
    // And the two refusals there already were still are.
    try std.testing.expectError(error.NoRole, parseRest(&.{"--group=g"}));
    try std.testing.expectError(error.ExtraArgument, parseRest(&.{ "r", "c", "x", "--group=g" }));
}

test "+launch: the session named on the line is the one the adapter is sent, and none named is a null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const choice: persona.CliChoice = .{ .cli = "claude-code" };
    inline for (.{
        .{ &[_][]const u8{ "r", "claude-code", "--resume=s-1" }, @as(?[]const u8, "s-1") },
        .{ &[_][]const u8{ "r", "claude-code" }, @as(?[]const u8, null) },
    }) |cell| {
        const parsed = try parseRest(cell[0]);
        var request: std.Io.Writer.Allocating = .init(aa);
        try agent_cli.writeLaunchRequest(&request.writer, .{ .key = "r", .name = "R" }, choice, null, null, null, parsed.session);
        const json = try std.json.parseFromSliceLeaky(std.json.Value, aa, request.written(), .{});
        const sent = json.object.get("session").?;
        if (cell[1]) |want| {
            try std.testing.expectEqualStrings(want, sent.string);
        } else {
            try std.testing.expect(sent == .null);
        }
    }
}

test "+launch: what follows `--` reaches the adapter after the role's own args" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const choice: persona.CliChoice = .{ .cli = "claude-code", .args = &.{"--verbose"} };
    const parsed = try parseRest(&.{ "dev-worker", "claude-code", "--", "-r", "x y" });
    const sent = try withPassthrough(aa, choice, parsed.passthrough);

    var request: std.Io.Writer.Allocating = .init(aa);
    try agent_cli.writeLaunchRequest(
        &request.writer,
        .{ .key = "dev-worker", .name = "Dev worker" },
        sent,
        null,
        null,
        null,
        null,
    );
    const json = try std.json.parseFromSliceLeaky(std.json.Value, aa, request.written(), .{});
    const args = json.object.get("cli").?.object.get("args").?.array.items;
    try std.testing.expectEqual(3, args.len);
    try std.testing.expectEqualStrings("--verbose", args[0].string);
    try std.testing.expectEqualStrings("-r", args[1].string);
    try std.testing.expectEqualStrings("x y", args[2].string);
}
