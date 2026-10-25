const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const AgentEvent = @import("../poltergeist/agent_event.zig");
const transport = @import("../poltergeist/transport.zig");
const Server = @import("../poltergeist/Server.zig");

const log = std.log.scoped(.hook);

/// The most of a hook's payload that is read. A `Stop` payload carries the
/// whole final answer, which is cut to `AgentEvent.max_text_bytes` after it
/// is parsed; this only bounds what a runaway writer can make us hold.
const max_stdin_bytes = 4 * 1024 * 1024;

/// The reader's fill window for the answer line, and **exactly enough** --
/// which is why these two reads are still `takeDelimiter` (task 2236).
///
/// Everything else in this tree that read a line with `takeDelimiter` was
/// reading bytes somebody else chose the length of, and `readline.zig` says
/// what that cost. These two are not that: **both answers are Polter's own,
/// and both are a fixed set of sentences.** Ten times over would still fit.
///
/// * The `auth` answer (see `deliver`) is `{"ok":true}` (12 bytes,
///   `wire.writeResponse(.ok)`) or one of `Server.zig`'s three refusals,
///   whose longest message is `"every agent slot on this socket is in use"`
///   -- about 100 bytes all told. `Server.handshake` sends nothing else.
/// * The `agent_event` answer is `.ok` (12 bytes; `rpc.zig`'s arm for that
///   method only returns `.ok`) or `.failed`, whose message comes from
///   `rpc.errorMessage` or `Server.refuse`. **Measured arm by arm**: the
///   longest is `AuthoriseOff`, 849 bytes of text and 896 bytes once
///   `std.json` has escaped it, and the `Shielded` case adds an 18-byte
///   `0x…: ` prefix. `LogsClosed` -- the one failure that formats a
///   directory path in -- cannot be reached from here: it needs a request
///   that names a `group`, and an `agent_event` carries none.
///
/// So the worst case is a quarter of this buffer, and the reason it will
/// stay that way is written down here rather than left as a measurement
/// somebody has to redo. **If either answer ever grows a field whose length
/// is not ours** -- a path from the client, an upstream's text -- this
/// stops being true and the read has to move to `readline.readLine` like
/// the rest. That is what this note is for.
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

    const argv = argsAfter(aa, "+hook") catch |err| {
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
    var ev = AgentEvent.translate(aa, args.cli, args.event, payload) catch |err| {
        // `Ignored` is a table choosing not to pass something on, not a
        // fault.
        if (err == error.Ignored) return;
        return err;
    };
    fillAnswer(aa, io, &ev);

    try deliver(
        io,
        socket_path orelse return error.NoSocket,
        token orelse return error.NoToken,
        ev,
    );
}

/// How much of a transcript's end is read for an answer. One step is one
/// line, and the answer is the last of them; this is room for a long one,
/// and bounds what the transcript of a long day costs to look at.
const max_transcript_tail = 256 * 1024;

/// A finished turn's answer, for a CLI whose `Stop` does not carry it but
/// whose transcript does (task 1682: Antigravity, `AgentEvent.agyAnswer`).
/// Read here rather than in `translate`, so that one stays a pure function
/// of the payload. Anything that goes wrong -- no path, no file, nothing
/// that reads as an answer -- leaves the turn without text, which is what
/// it had before; it is never a reason not to deliver the turn.
fn fillAnswer(aa: Allocator, io: std.Io, ev: *AgentEvent.Event) void {
    if (ev.event != .turn_ended or ev.text != null) return;
    if (!std.mem.eql(u8, ev.cli, "antigravity")) return;
    const path = ev.transcript_path orelse return;
    if (!std.fs.path.isAbsolute(path)) return;

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);
    const size = (file.stat(io) catch return).size;
    if (size == 0) return;
    const want: usize = @intCast(@min(size, max_transcript_tail));
    const buf = aa.alloc(u8, want) catch return;
    const n = file.readPositionalAll(io, buf, size - want) catch return;

    const text = AgentEvent.agyAnswer(aa, buf[0..n], want == size) orelse return;
    ev.text = AgentEvent.cutBytes(text, AgentEvent.max_text_bytes);
    ev.text_bytes = text.len;
}

/// The arguments after our own `+hook` token (or `+hook-context`'s, which
/// takes the same ones). Read by hand for the reason `+launch` gives: the
/// shared iterator takes no positionals.
pub fn argsAfter(aa: Allocator, action: []const u8) ![]const []const u8 {
    var iter: std.process.Args.Iterator = try .initAllocator(global.args(), aa);
    defer iter.deinit();

    _ = iter.next(); // argv0
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, action)) break;
    } else return error.NoEvent;

    var out: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try out.append(aa, try aa.dupe(u8, arg));
    return out.items;
}

pub const Args = struct {
    cli: []const u8,
    event: []const u8,
};

/// `--cli <cli> <event>`.
pub fn parseArgs(argv: []const []const u8) !Args {
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

    // A connection turned away for want of a slot is answered and closed
    // the moment it is accepted, so writing the token can fail on a
    // connection whose answer is already here to read (task 1736). The
    // answer is what says why; the failed write is only what it looked
    // like from this end.
    const sent = sendAuth(w, token);
    const auth = (reader.interface.takeDelimiter('\n') catch |err| {
        try sent;
        return err;
    }) orelse {
        try sent;
        return error.EndOfStream;
    };
    try admitted(auth);
    try sent;

    var line_buf: [Server.max_request_bytes - 1]u8 = undefined;
    try w.writeAll(try fitRequest(&line_buf, ev));
    try w.writeByte('\n');
    try w.flush();

    const reply = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
        log.warn("+hook: refused: {s}", .{reply[0..@min(reply.len, 200)]});
        return error.Refused;
    }
}

pub fn sendAuth(w: *std.Io.Writer, token: []const u8) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("method");
    try s.write("auth");
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("token");
    try s.write(token);
    // Not an agent (task 1747): see `Server.Kind.hook`.
    try s.objectField("kind");
    try s.write(@tagName(Server.Kind.hook));
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}

/// Whether the first line back let this connection in, and if not, which
/// refusal it was (task 1736). **Two refusals that are not one**: every
/// slot in use is a busy Polter, a token it does not know is a terminal
/// that is not its own, and a log that called both `AuthRefused` sent
/// whoever read it after a token -- 413 times in ten minutes, measured on
/// a machine whose tokens were all fine. The code is the server's
/// (`Server.full_refusal_code`), matched the way `+mcp` matches it.
pub fn admitted(line: []const u8) error{ AgentsFull, AuthRefused }!void {
    if (std.mem.indexOf(u8, line, "\"ok\":true") != null) return;
    if (std.mem.indexOf(u8, line, Server.full_refusal_code) != null) return error.AgentsFull;
    return error.AuthRefused;
}

/// The `agent_event` request line, without its newline, written into `buf`
/// and cut until it fits there (task 1651).
///
/// An approval carries its whole tool call, and the host reads no request
/// longer than `Server.max_request_bytes` -- it drops the connection, and
/// the approval would never be heard. So the tool call is halved until the
/// line fits, then the text; `input_bytes` and `text_bytes` still say how
/// long each was, so what arrives says it was cut. What is cut is
/// measured after JSON escaping, which no fixed budget can: a command of
/// control characters is six times its length on the wire.
pub fn fitRequest(buf: []u8, ev: AgentEvent.Event) error{TooLong}![]const u8 {
    var e = ev;
    while (true) {
        var w: std.Io.Writer = .fixed(buf);
        if (writeRequest(&w, e)) |_| return w.buffered() else |_| {}
        if (e.input) |s| if (s.len > 0) {
            e.input = AgentEvent.cutBytes(s, s.len / 2);
            continue;
        };
        if (e.text) |s| if (s.len > 0) {
            e.text = AgentEvent.cutBytes(s, s.len / 2);
            continue;
        };
        return error.TooLong;
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
    inline for (.{ "session_id", "agent_id", "transcript_path", "detail", "note", "text" }) |name| {
        if (@field(ev, name)) |v| {
            try s.objectField(name);
            try s.write(v);
        }
    }
    if (ev.text != null) {
        try s.objectField("text_bytes");
        try s.write(ev.text_bytes);
    }
    if (ev.input) |v| {
        try s.objectField("input");
        try s.write(v);
        try s.objectField("input_bytes");
        try s.write(ev.input_bytes);
    }
    if (ev.waiting_on_background) {
        try s.objectField("waiting_on_background");
        try s.write(true);
    }
    // Left out when null, which for `context_reported` is the CLI having
    // no number yet (`wire.contextUsed` reads absence that way).
    if (ev.context_used) |p| {
        try s.objectField("context_used");
        try s.write(p);
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
    ev.agent_id = "a36a9e16d5b37235e";
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
    try testing.expectEqualStrings("a36a9e16d5b37235e", got.agent_id.?);
    try testing.expectEqualStrings(ev.text.?, got.text.?);
    try testing.expectEqual(@as(u64, 999), got.text_bytes);
    try testing.expect(got.waiting_on_background);
    try testing.expect(got.detail == null);
    try testing.expect(got.note == null);
}

test "1779: how full the context is reaches the host as said, and no number as no number" {
    for ([_]?u8{ 0, 73, 100, null }) |used| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var ev: AgentEvent.Event = .none;
        ev.event = .context_reported;
        ev.cli = "claude-code";
        ev.context_used = used;
        try writeRequest(&w, ev);

        var p = try wire.parseRequest(testing.allocator, w.buffered());
        defer p.deinit();
        const got = p.value.agent_event;
        try testing.expectEqual(AgentEvent.Kind.context_reported, got.event);
        try testing.expectEqual(used, got.context_used);
    }

    // A number that is not a percentage is refused, not kept.
    try testing.expectError(error.BadParams, wire.parseRequest(testing.allocator,
        \\{"method":"agent_event","params":{"event":"context_reported","cli":"claude-code","context_used":101}}
    ));
}

test "an approval's whole tool call reaches the host, and is cut to fit when it would not (task 1651)" {
    var buf: [Server.max_request_bytes - 1]u8 = undefined;
    var ev: AgentEvent.Event = .none;
    ev.event = .awaiting_approval;
    ev.cli = "claude-code";
    ev.detail = "Bash";
    ev.text = "rm -rf dist";
    ev.text_bytes = 11;
    ev.input = "{\"command\":\"rm -rf dist\",\"description\":\"clean\"}";
    ev.input_bytes = ev.input.?.len;
    {
        var p = try wire.parseRequest(testing.allocator, try fitRequest(&buf, ev));
        defer p.deinit();
        try testing.expectEqualStrings(ev.input.?, p.value.agent_event.input.?);
        try testing.expectEqual(ev.input_bytes, p.value.agent_event.input_bytes);
    }

    // A tool call of quotes doubles on the wire: 24 KB of them is 48 KB,
    // and with 16 KB of control characters as the text, six times over,
    // nothing fits until it is cut.
    const quotes: [AgentEvent.max_input_bytes]u8 = @splat('"');
    const bells: [AgentEvent.max_text_bytes]u8 = @splat(7);
    ev.input = &quotes;
    ev.input_bytes = 100_000;
    ev.text = &bells;
    ev.text_bytes = bells.len;
    const line = try fitRequest(&buf, ev);
    try testing.expect(line.len < Server.max_request_bytes);
    var p = try wire.parseRequest(testing.allocator, line);
    defer p.deinit();
    const got = p.value.agent_event;
    try testing.expect(got.input.?.len < quotes.len);
    // Still says how long it was.
    try testing.expectEqual(@as(u64, 100_000), got.input_bytes);
    try testing.expectEqual(@as(u64, bells.len), got.text_bytes);
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

test "1682: an antigravity turn's answer is read from its transcript, and nothing else's is" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const path = try std.fmt.allocPrint(aa, "/tmp/pgh-transcript-{x}.jsonl", .{&raw});
    {
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\{"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "content": "say done"}
            \\{"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "content": "done"}
            \\
        );
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const stop = try std.fmt.allocPrint(aa,
        \\{{"conversationId":"c","terminationReason":"NO_TOOL_CALL","error":"","fullyIdle":true,"transcriptPath":"{s}"}}
    , .{path});
    var ev = try AgentEvent.translate(aa, "antigravity", "Stop", stop);
    try testing.expect(ev.text == null);
    fillAnswer(aa, io, &ev);
    try testing.expectEqualStrings("done", ev.text.?);
    try testing.expectEqual(@as(u64, 4), ev.text_bytes);

    // Only a finished turn: a tool starting reads nothing.
    const pre = try std.fmt.allocPrint(aa,
        \\{{"conversationId":"c","toolCall":{{"name":"run_command"}},"transcriptPath":"{s}"}}
    , .{path});
    var tool = try AgentEvent.translate(aa, "antigravity", "PreToolUse", pre);
    fillAnswer(aa, io, &tool);
    try testing.expect(tool.text == null);

    // A file that is not there leaves the turn as it was.
    const gone = try std.fmt.allocPrint(aa,
        \\{{"conversationId":"c","terminationReason":"NO_TOOL_CALL","transcriptPath":"{s}.gone"}}
    , .{path});
    var missing = try AgentEvent.translate(aa, "antigravity", "Stop", gone);
    fillAnswer(aa, io, &missing);
    try testing.expect(missing.text == null);

    // Another CLI's transcript is not this reader's to read.
    var other = try AgentEvent.translate(aa, "claude-code", "Stop", try std.fmt.allocPrint(aa,
        \\{{"session_id":"s","hook_event_name":"Stop","transcript_path":"{s}"}}
    , .{path}));
    fillAnswer(aa, io, &other);
    try testing.expect(other.text == null);
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
