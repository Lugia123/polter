const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const AgentEvent = @import("../poltergeist/agent_event.zig");
const transport = @import("../poltergeist/transport.zig");

const log = std.log.scoped(.hook);

/// The most of a hook's payload that is read. A `Stop` payload carries the
/// whole final answer, which is cut to `AgentEvent.max_text_bytes` after it
/// is parsed; this only bounds what a runaway writer can make us hold.
const max_stdin_bytes = 4 * 1024 * 1024;

/// Longest reply line read back. The answer to `agent_event` is `ok`.
const max_reply = 4 * 1024;

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

/// The `hook` command tells Polter what an agent CLI is doing. It is run by
/// the CLI's own hooks, which a role's adapter configures when it starts
/// the CLI; it is not run by hand.
///
///   polter +hook --cli <cli> <event>
///
/// It reads the hook's JSON payload on stdin, translates it into Polter's
/// own vocabulary for that CLI, and sends it to the terminal it runs in,
/// found through `GHOSTTY_POLTER_SOCKET` and `GHOSTTY_POLTER_TOKEN` -- the
/// CLI's hooks inherit its environment, so this is that terminal.
///
/// **It always exits 0 and never writes to stdout**, whatever goes wrong.
/// The CLI reads a hook's exit code and stdout to decide what to do next
/// (Claude Code blocks on exit 2 and treats JSON on stdout as a decision),
/// and Polter being down must never stop or change an agent's turn.
/// Failures go to Polter's log only.
pub fn run(alloc: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const argv = argsAfterHook(aa) catch |err| {
        log.warn("+hook: could not read the command line err={t}", .{err});
        return 0;
    };
    var env = global.environMap() catch |err| {
        log.warn("+hook: could not read the environment err={t}", .{err});
        return 0;
    };
    defer env.deinit();

    return runWith(
        aa,
        global.io(),
        argv,
        env.get("GHOSTTY_POLTER_SOCKET"),
        env.get("GHOSTTY_POLTER_TOKEN"),
    );
}

/// Everything `run` does once it has its arguments and environment, so a
/// test can drive the real path. Reads stdin; never touches stdout; always
/// answers 0.
pub fn runWith(
    aa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    socket_path: ?[]const u8,
    token: ?[]const u8,
) u8 {
    handle(aa, io, argv, socket_path, token) catch |err| {
        log.warn("+hook: event not delivered err={t}", .{err});
    };
    return 0;
}

fn handle(
    aa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    socket_path: ?[]const u8,
    token: ?[]const u8,
) !void {
    // Read before anything else can fail, so the CLI's pipe is always
    // drained whatever happens next.
    var stdin: std.Io.File = .stdin();
    var in_buf: [16 * 1024]u8 = undefined;
    var reader = stdin.reader(io, &in_buf);
    const payload = try reader.interface.allocRemaining(aa, .limited(max_stdin_bytes));

    const args = try parseArgs(argv);
    const ev = AgentEvent.translate(aa, args.cli, args.event, payload) catch |err| {
        // `Ignored` is a table choosing not to pass something on, not a
        // fault.
        if (err == error.Ignored) return;
        return err;
    };

    try deliver(
        io,
        socket_path orelse return error.NoSocket,
        token orelse return error.NoToken,
        ev,
    );
}

/// The arguments after our own `+hook` token. Read by hand for the reason
/// `+launch` gives: the shared iterator takes no positionals.
fn argsAfterHook(aa: Allocator) ![]const []const u8 {
    var iter: std.process.Args.Iterator = try .initAllocator(global.args(), aa);
    defer iter.deinit();

    _ = iter.next(); // argv0
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+hook")) break;
    } else return error.NoEvent;

    var out: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try out.append(aa, try aa.dupe(u8, arg));
    return out.items;
}

const Args = struct {
    cli: []const u8,
    event: []const u8,
};

/// `--cli <cli> <event>`.
fn parseArgs(argv: []const []const u8) !Args {
    var cli: ?[]const u8 = null;
    var event: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--cli")) {
            i += 1;
            if (i == argv.len) return error.NoCli;
            cli = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--cli=")) {
            cli = arg["--cli=".len..];
        } else if (event == null) {
            event = arg;
        } else return error.TooManyArguments;
    }
    return .{
        .cli = cli orelse return error.NoCli,
        .event = event orelse return error.NoEvent,
    };
}

/// Send one event to the terminal whose token this is, and wait for the
/// answer. `pub` because `+launch` says `hooks_expected` the same way.
///
/// Not `mcp.Host.connect`: that one explains a refusal on stderr for a
/// person starting an agent, and nobody reads a hook's stderr.
pub fn deliver(
    io: std.Io,
    socket_path: []const u8,
    token: []const u8,
    ev: AgentEvent.Event,
) !void {
    const conn = try transport.connect(io, socket_path);
    defer conn.close(io);

    var read_buf: [max_reply]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    const w = &writer.interface;

    {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("method");
        try s.write("auth");
        try s.objectField("params");
        try s.beginObject();
        try s.objectField("token");
        try s.write(token);
        try s.endObject();
        try s.endObject();
        try w.writeByte('\n');
        try w.flush();
    }
    const auth = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    if (std.mem.indexOf(u8, auth, "\"ok\":true") == null) return error.AuthRefused;

    try writeRequest(w, ev);
    try w.writeByte('\n');
    try w.flush();

    const reply = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
        log.warn("+hook: refused: {s}", .{reply[0..@min(reply.len, 200)]});
        return error.Refused;
    }
}

/// The `agent_event` request line, without its newline. Fields that are
/// null are left out, which `wire.parseAgentEvent` reads as absent.
pub fn writeRequest(w: *std.Io.Writer, ev: AgentEvent.Event) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("method");
    try s.write("agent_event");
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("event");
    try s.write(@tagName(ev.event));
    try s.objectField("cli");
    try s.write(ev.cli);
    inline for (.{ "session_id", "detail", "note", "text" }) |name| {
        if (@field(ev, name)) |v| {
            try s.objectField(name);
            try s.write(v);
        }
    }
    if (ev.text != null) {
        try s.objectField("text_bytes");
        try s.write(ev.text_bytes);
    }
    if (ev.waiting_on_background) {
        try s.objectField("waiting_on_background");
        try s.write(true);
    }
    try s.endObject();
    try s.endObject();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const wire = @import("../poltergeist/wire.zig");

test "the request +hook writes is the one the host parses back" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ev: AgentEvent.Event = .none;
    ev.event = .turn_ended;
    ev.cli = "claude-code";
    ev.session_id = "s1";
    ev.text = "done \"quoted\"\nnext line";
    ev.text_bytes = 999;
    ev.waiting_on_background = true;
    try writeRequest(&w, ev);

    var p = try wire.parseRequest(testing.allocator, w.buffered());
    defer p.deinit();
    const got = p.value.agent_event;
    try testing.expectEqual(AgentEvent.Kind.turn_ended, got.event);
    try testing.expectEqualStrings("claude-code", got.cli);
    try testing.expectEqualStrings("s1", got.session_id.?);
    try testing.expectEqualStrings(ev.text.?, got.text.?);
    try testing.expectEqual(@as(u64, 999), got.text_bytes);
    try testing.expect(got.waiting_on_background);
    try testing.expect(got.detail == null);
    try testing.expect(got.note == null);
}

test "an event with nothing optional still parses" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ev: AgentEvent.Event = .none;
    ev.cli = "claude-code";
    try writeRequest(&w, ev);

    var p = try wire.parseRequest(testing.allocator, w.buffered());
    defer p.deinit();
    try testing.expectEqual(AgentEvent.Kind.hooks_expected, p.value.agent_event.event);
    try testing.expect(p.value.agent_event.text == null);
    try testing.expect(!p.value.agent_event.waiting_on_background);
}

// -- the process: exit code and stdout --------------------------------------
//
// adapters.md section 7 asks for `+hook` to exit 0 with nothing on stdout
// when the socket is missing, the token is wrong, or stdin is not JSON. Those
// are properties of a process, so they are measured on one: the real
// `runWith` runs in a forked child whose fd 0 and fd 1 are pipes, and the
// parent reads the exit status and counts every byte that reached fd 1.
//
// A child that delivers is the control: the same harness sees the event
// arrive, so a bad case that "delivered nothing" is known to have been in a
// position to deliver.

const builtin = @import("builtin");
const Server = @import("../poltergeist/Server.zig");

const Seen = struct {
    io: std.Io,
    events: std.atomic.Value(u32) = .init(0),
    other: std.atomic.Value(u32) = .init(0),

    fn submit(ctx: *anyopaque, pending: *Server.Pending) void {
        const self: *Seen = @ptrCast(@alignCast(ctx));
        defer pending.release();
        switch (pending.request) {
            .agent_event => _ = self.events.fetchAdd(1, .acq_rel),
            else => _ = self.other.fetchAdd(1, .acq_rel),
        }
        pending.complete(self.io, .ok);
    }
};

const Ran = struct { code: u8, stdout_bytes: usize };

fn runChild(
    argv: []const []const u8,
    socket_path: ?[]const u8,
    token: ?[]const u8,
    payload: []const u8,
) !Ran {
    const sys = std.posix.system;
    var in_pipe: [2]std.posix.fd_t = undefined;
    var out_pipe: [2]std.posix.fd_t = undefined;
    if (sys.pipe(&in_pipe) != 0) return error.Pipe;
    if (sys.pipe(&out_pipe) != 0) return error.Pipe;

    const pid = sys.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        // The child: its own stdin and stdout, its own `Io`, its own
        // memory. Nothing from the parent's threads is used here.
        _ = sys.dup2(in_pipe[0], 0);
        _ = sys.dup2(out_pipe[1], 1);
        _ = sys.close(in_pipe[0]);
        _ = sys.close(in_pipe[1]);
        _ = sys.close(out_pipe[0]);
        _ = sys.close(out_pipe[1]);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const code = runWith(arena.allocator(), threaded.io(), argv, socket_path, token);
        std.c._exit(code);
    }

    _ = sys.close(in_pipe[0]);
    _ = sys.close(out_pipe[1]);

    var off: usize = 0;
    while (off < payload.len) {
        const n = std.c.write(in_pipe[1], payload[off..].ptr, payload.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = sys.close(in_pipe[1]);

    var total: usize = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(out_pipe[0], &buf, buf.len);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = sys.close(out_pipe[0]);

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.Wait;
    const s: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(s)) return error.ChildDidNotExit;
    return .{ .code = std.posix.W.EXITSTATUS(s), .stdout_bytes = total };
}

const good_stop =
    \\{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"done","background_tasks":[]}
;
const stop_argv: []const []const u8 = &.{ "--cli", "claude-code", "Stop" };

const Live = struct {
    threaded: std.Io.Threaded,
    seen: Seen,
    path: [:0]u8,
    server: Server,
    token: []const u8,

    fn setup(self: *Live) !void {
        const alloc = testing.allocator;
        self.threaded = .init(alloc, .{});
        const io = self.threaded.io();
        self.seen = .{ .io = io };
        var raw: [6]u8 = undefined;
        io.random(&raw);
        self.path = try std.fmt.allocPrintSentinel(alloc, "/tmp/pgh-{x}.sock", .{&raw}, 0);
        self.server = try .init(alloc, io, self.path, .{
            .ctx = &self.seen,
            .func = Seen.submit,
        }, Server.default_max_connections);
        try self.server.start();
        self.token = try self.server.issueToken(0x2222);
    }

    fn deinit(self: *Live) void {
        self.server.deinit();
        testing.allocator.free(self.path);
        self.threaded.deinit();
    }
};

test "+hook delivers a good event, and says nothing on stdout while it does" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup();
    defer live.deinit();

    const ran = try runChild(stop_argv, live.path, live.token, good_stop);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    try testing.expectEqual(@as(u32, 1), live.seen.events.load(.acquire));
}

test "+hook with no socket there exits 0 and writes nothing to stdout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ran = try runChild(stop_argv, "/tmp/pgh-no-such-socket.sock", "0" ** Server.token_len, good_stop);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
}

test "+hook with a wrong token exits 0, writes nothing to stdout, delivers nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup();
    defer live.deinit();

    const ran = try runChild(stop_argv, live.path, "0" ** Server.token_len, good_stop);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    try testing.expectEqual(@as(u32, 0), live.seen.events.load(.acquire));
}

test "+hook with stdin that is not JSON exits 0, writes nothing to stdout, delivers nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup();
    defer live.deinit();

    const ran = try runChild(stop_argv, live.path, live.token, "this is not { json");
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    try testing.expectEqual(@as(u32, 0), live.seen.events.load(.acquire));
}
