const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const hook = @import("hook.zig");
const hook_context = @import("hook_context.zig");
const readline = @import("readline.zig");
const transport = @import("../poltergeist/transport.zig");

const log = std.log.scoped(.hook_guard);

/// The most of a hook's payload that is read. A `Write` payload carries the
/// whole file it is about to write; only `tool_input.file_path` is wanted,
/// and this bounds what the content of a very large file costs to look at.
const max_stdin_bytes = 16 * 1024 * 1024;

/// The reader's fill window for the answer line; see `hook_context.zig`.
const max_reply = 64 * 1024;

/// **How long Polter has to answer, and how long this whole process lives.**
/// A hook that blocks holds an agent's tool call, so the deadline is for
/// the process, not for one read: a Polter that accepts the connection and
/// never answers, a pipe that never closes and a socket that hangs are all
/// the same thing from here (PLAN 1.5).
pub const timeout_ms: u32 = 800;

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

/// The `hook-guard` command refuses an agent's write to a file the person is
/// editing in Polter (task 2565 C6a). It is run by Claude Code's own
/// `PreToolUse` hook on its file-writing tools, which a role's adapter
/// configures when it starts the CLI; it is not run by hand.
///
///   polter +hook-guard
///
/// It reads the hook's JSON payload on stdin, asks the terminal it runs in
/// (through `GHOSTTY_POLTER_SOCKET` and `GHOSTTY_POLTER_TOKEN`) whether the
/// file is locked, and when it is, prints the `PreToolUse` decision that
/// denies the call.
///
/// **It writes to stdout in exactly one case, and every other case is exit 0
/// with nothing there.** Claude Code reads a hook's stdout as a decision, so
/// a guard that printed anything else -- a log line, a half answer -- could
/// stop writes that nobody locked. Polter not running, no socket, a token it
/// does not know, a payload it cannot read, a path in no working directory,
/// an answer that is not the whole sentence, and an answer that comes after
/// `timeout_ms` are all "let it through". Failures go to Polter's log only.
pub fn run(alloc: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var env = global.environMap() catch |err| {
        log.warn("+hook-guard: could not read the environment err={t}", .{err});
        return 0;
    };
    defer env.deinit();

    return runWith(
        aa,
        global.io(),
        env.get("GHOSTTY_POLTER_SOCKET"),
        env.get("GHOSTTY_POLTER_TOKEN"),
    );
}

/// Everything `run` does once it has its environment, so a test can drive
/// the real path. Reads stdin; writes stdout only for a denial; always
/// answers 0.
pub fn runWith(
    aa: Allocator,
    io: std.Io,
    socket_path: ?[]const u8,
    token: ?[]const u8,
) u8 {
    // Started before anything that can block: the deadline covers the stdin
    // read, the connect and the answer alike.
    const dog = std.Thread.spawn(.{}, Gate.watch, .{io}) catch |err| {
        // Without the deadline there is no promise to keep; let it through
        // rather than risk holding the agent.
        log.warn("+hook-guard: no watchdog thread err={t}", .{err});
        return 0;
    };
    dog.detach();

    var stdin: std.Io.File = .stdin();
    var in_buf: [16 * 1024]u8 = undefined;
    var reader = stdin.reader(io, &in_buf);
    const payload = reader.interface.allocRemaining(aa, .limited(max_stdin_bytes)) catch |err| {
        log.warn("+hook-guard: could not read stdin err={t}", .{err});
        return 0;
    };

    const out = answer(aa, io, payload, socket_path, token) orelse return 0;
    // Past the deadline the process is already going: nothing is written.
    if (!Gate.claim()) return 0;
    std.Io.File.stdout().writeStreamingAll(io, out) catch |err| {
        log.warn("+hook-guard: could not write the answer err={t}", .{err});
    };
    return 0;
}

/// Who gets to end this process: the answer, or the clock. Whichever moves
/// the state first decides, so a denial is never half written by a process
/// the clock is about to end.
const Gate = struct {
    /// **File scope, not the caller's stack**: the watchdog thread is
    /// detached and may wake after `runWith` has returned.
    var state: std.atomic.Value(u8) = .init(running);

    const running: u8 = 0;
    const answering: u8 = 1;
    const expired: u8 = 2;

    /// The main thread is about to write. False when the clock got there
    /// first.
    fn claim() bool {
        return state.cmpxchgStrong(running, answering, .acq_rel, .acquire) == null;
    }

    fn watch(io: std.Io) void {
        io.sleep(.fromMilliseconds(timeout_ms), .awake) catch {};
        if (state.cmpxchgStrong(running, expired, .acq_rel, .acquire) != null) return;
        log.warn("+hook-guard: Polter did not answer in {d}ms; letting the write through", .{timeout_ms});
        // `_exit` and not `exit`: the main thread may be inside a read, and
        // nothing is to be flushed or unwound.
        switch (builtin.os.tag) {
            .windows => std.process.exit(0),
            else => std.c._exit(0),
        }
    }
};

/// What to print, or null to print nothing. Everything `run` does after
/// reading its input, so a test can drive the real path.
pub fn answer(
    aa: Allocator,
    io: std.Io,
    payload: []const u8,
    socket_path: ?[]const u8,
    token: ?[]const u8,
) ?[]const u8 {
    const path = pathOf(aa, payload) orelse return null;
    const reason = ask(
        io,
        aa,
        socket_path orelse return null,
        token orelse return null,
        path,
    ) catch |err| {
        log.warn("+hook-guard: Polter did not answer err={t}", .{err});
        return null;
    };
    if (reason.len == 0) return null;
    return render(aa, reason) catch null;
}

/// The absolute path of the file the tool call is about, or null when the
/// payload has none or it cannot be made absolute. Claude Code's file tools
/// say `file_path`, its notebook tool says `notebook_path`; a relative one is
/// taken from the payload's `cwd`, and with none the call is let through --
/// Polter is not told a path it would have to guess the meaning of.
///
/// **Only the tools that write are asked about** (`writing_tools`); `Read`
/// and the rest carry a `file_path` too, and a guard that took every
/// `file_path` would refuse an agent *reading* a locked file if the hook were
/// ever registered wider than it should be.
pub fn pathOf(aa: Allocator, payload: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, aa, payload, .{}) catch return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const tool = switch (obj.get("tool_name") orelse return null) {
        .string => |t| t,
        else => return null,
    };
    for (writing_tools) |t| {
        if (std.mem.eql(u8, t, tool)) break;
    } else return null;
    const input = switch (obj.get("tool_input") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const raw = for ([_][]const u8{ "file_path", "notebook_path" }) |key| {
        const v = input.get(key) orelse continue;
        switch (v) {
            .string => |s| if (s.len > 0) break s,
            else => {},
        }
    } else return null;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return null;
    if (std.fs.path.isAbsolute(raw)) return raw;
    const cwd = switch (obj.get("cwd") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!std.fs.path.isAbsolute(cwd)) return null;
    return std.fs.path.resolve(aa, &.{ cwd, raw }) catch null;
}

/// The tools whose calls change a file.
pub const writing_tools = [_][]const u8{ "Write", "Edit", "MultiEdit", "NotebookEdit" };

/// The bytes Claude Code reads as "do not run this tool call".
pub fn render(aa: Allocator, reason: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(aa);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("hookSpecificOutput");
    try s.beginObject();
    try s.objectField("hookEventName");
    try s.write("PreToolUse");
    try s.objectField("permissionDecision");
    try s.write("deny");
    try s.objectField("permissionDecisionReason");
    try s.write(reason);
    try s.endObject();
    try s.endObject();
    try out.writer.writeByte('\n');
    return out.written();
}

/// Ask the terminal whose token this is whether `path` is locked: the
/// sentence to hand the agent, or an empty one for "no".
fn ask(
    io: std.Io,
    aa: Allocator,
    socket_path: []const u8,
    token: []const u8,
    path: []const u8,
) ![]const u8 {
    const conn = try transport.connect(io, socket_path);
    defer conn.close(io);

    const read_buf = try aa.alloc(u8, max_reply);
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, read_buf);
    var writer = conn.writer(io, &write_buf);
    const w = &writer.interface;

    // As `hook_context.ask` does it, and for its reason (task 1736).
    const sent = hook.sendAuth(w, token);
    const auth = (reader.interface.takeDelimiter('\n') catch |err| {
        try sent;
        return err;
    }) orelse {
        try sent;
        return error.EndOfStream;
    };
    try hook.admitted(auth);
    try sent;

    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("method");
    try s.write("file_guard");
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("path");
    try s.write(path);
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();

    var reply_buf: std.Io.Writer.Allocating = .init(aa);
    defer reply_buf.deinit();
    const reply = readline.readLine(&reader.interface, &reply_buf, readline.max_reply) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.LineTooLong, error.ReadFailed, error.OutOfMemory => return error.Refused,
    };
    // `text` of an ok reply, as `+hook-context` reads it; a refusal is
    // "not locked", never its message.
    // An empty `text` is the ordinary "not locked" and is not a refusal, so
    // it is not logged as one.
    if (hook_context.textOf(aa, reply)) |t| return t;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, reply, .{}) catch return error.Refused;
    const ok = switch (parsed) {
        .object => |o| o.get("ok") orelse return error.Refused,
        else => return error.Refused,
    };
    if (ok == .bool and ok.bool) return "";
    log.warn("+hook-guard: refused: {s}", .{reply[0..@min(reply.len, 200)]});
    return error.Refused;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Server = @import("../poltergeist/Server.zig");

test "2565 C6: the path is the file the tool call is about, made absolute, or nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Case = struct { payload: []const u8, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/w/a/x.md\"}}", .want = "/w/a/x.md" },
        .{ .payload = "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"/w/a/n.ipynb\"}}", .want = "/w/a/n.ipynb" },
        .{ .payload = "{\"cwd\":\"/w/a\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"docs/../x.md\"}}", .want = "/w/a/x.md" },
        // Relative with nothing to anchor it: not guessed.
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"x.md\"}}", .want = null },
        // A tool that only reads has a `file_path` too, and is never asked
        // about; neither is a payload that does not say which tool it is.
        .{ .payload = "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/w/a/x.md\"}}", .want = null },
        .{ .payload = "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"/w/a/x.md\"}}", .want = "/w/a/x.md" },
        .{ .payload = "{\"tool_input\":{\"file_path\":\"/w/a/x.md\"}}", .want = null },
        .{ .payload = "{\"tool_name\":5,\"tool_input\":{\"file_path\":\"/w/a/x.md\"}}", .want = null },
        .{ .payload = "{\"cwd\":\"w\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"x.md\"}}", .want = null },
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":{\"command\":\"ls\"}}", .want = null },
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\"}}", .want = null },
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":5}}", .want = null },
        .{ .payload = "{\"tool_name\":\"Write\",\"tool_input\":\"/w/a/x.md\"}", .want = null },
        .{ .payload = "[]", .want = null },
        .{ .payload = "this is not { json", .want = null },
    };
    for (cases) |c| {
        const got = pathOf(aa, c.payload);
        if (c.want) |w| {
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "2565 C6: the denial is the PreToolUse decision, with the reason whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const out = try render(aa, "w2 is editing \"/w/a/x.md\" in Polter.");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, aa, out, .{});
    const o = root.object.get("hookSpecificOutput").?.object;
    try testing.expectEqualStrings("PreToolUse", o.get("hookEventName").?.string);
    try testing.expectEqualStrings("deny", o.get("permissionDecision").?.string);
    try testing.expectEqualStrings("w2 is editing \"/w/a/x.md\" in Polter.", o.get("permissionDecisionReason").?.string);
    try testing.expect(out[out.len - 1] == '\n');
}

// -- the process: exit code and stdout --------------------------------------
//
// As `hook.zig`'s: the real `runWith` runs in a forked child whose fd 0 and
// fd 1 are pipes, and the parent reads the exit status and the bytes that
// reached fd 1. The control is the child that is denied -- the same harness
// sees the denial arrive, so a case that printed nothing is known to have
// been in a position to print.

/// Answers `file_guard`: locked when the path is `locked_path`, and says
/// how many times it was asked. `hang` makes it answer too late.
const Seen = struct {
    io: std.Io,
    locked_path: []const u8,
    hang: bool = false,
    asked: std.atomic.Value(u32) = .init(0),

    fn submit(ctx: *anyopaque, pending: *Server.Pending) void {
        const self: *Seen = @ptrCast(@alignCast(ctx));
        switch (pending.request) {
            .file_guard => |p| {
                _ = self.asked.fetchAdd(1, .acq_rel);
                defer pending.release();
                // A Polter that stopped: the answer comes long after the
                // deadline, to a client that is gone.
                if (self.hang) self.io.sleep(.fromMilliseconds(2000), .awake) catch {};
                const text: []const u8 = if (std.mem.eql(u8, p.path, self.locked_path))
                    "w2 is editing it in Polter."
                else
                    "";
                pending.complete(self.io, .{ .text = pending.arena.allocator().dupe(u8, text) catch "" });
            },
            else => {
                defer pending.release();
                pending.complete(self.io, .ok);
            },
        }
    }
};

const Ran = struct { code: u8, stdout_bytes: usize, stdout: [512]u8 };

fn runChild(socket_path: ?[]const u8, token: ?[]const u8, payload: []const u8) !Ran {
    const sys = std.posix.system;
    var in_pipe: [2]std.posix.fd_t = undefined;
    var out_pipe: [2]std.posix.fd_t = undefined;
    if (sys.pipe(&in_pipe) != 0) return error.Pipe;
    if (sys.pipe(&out_pipe) != 0) return error.Pipe;

    const pid = sys.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = sys.dup2(in_pipe[0], 0);
        _ = sys.dup2(out_pipe[1], 1);
        _ = sys.close(in_pipe[0]);
        _ = sys.close(in_pipe[1]);
        _ = sys.close(out_pipe[0]);
        _ = sys.close(out_pipe[1]);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const code = runWith(arena.allocator(), threaded.io(), socket_path, token);
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

    var ran: Ran = .{ .code = 0, .stdout_bytes = 0, .stdout = undefined };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(out_pipe[0], &buf, buf.len);
        if (n <= 0) break;
        const got: usize = @intCast(n);
        const room = ran.stdout.len -| ran.stdout_bytes;
        @memcpy(ran.stdout[ran.stdout_bytes..][0..@min(room, got)], buf[0..@min(room, got)]);
        ran.stdout_bytes += got;
    }
    _ = sys.close(out_pipe[0]);

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.Wait;
    const s: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(s)) return error.ChildDidNotExit;
    ran.code = std.posix.W.EXITSTATUS(s);
    return ran;
}

const locked_payload =
    \\{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/w/a/docs/x.md","content":"hi"}}
;
const free_payload =
    \\{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/w/a/docs/y.md","content":"hi"}}
;

const Live = struct {
    threaded: std.Io.Threaded,
    seen: Seen,
    path: [:0]u8,
    server: Server,
    token: []const u8,

    fn setup(self: *Live, hang: bool) !void {
        const alloc = testing.allocator;
        self.threaded = .init(alloc, .{});
        const io = self.threaded.io();
        self.seen = .{ .io = io, .locked_path = "/w/a/docs/x.md", .hang = hang };
        var raw: [6]u8 = undefined;
        io.random(&raw);
        self.path = try std.fmt.allocPrintSentinel(alloc, "/tmp/pgg-{x}.sock", .{&raw}, 0);
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

test "2565 C6: a locked file is denied on stdout, and exit is 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup(false);
    defer live.deinit();

    const ran = try runChild(live.path, live.token, locked_payload);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(u32, 1), live.seen.asked.load(.acquire));
    try testing.expect(ran.stdout_bytes > 0);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), ran.stdout[0..ran.stdout_bytes], .{});
    const o = root.object.get("hookSpecificOutput").?.object;
    try testing.expectEqualStrings("deny", o.get("permissionDecision").?.string);
    try testing.expectEqualStrings("w2 is editing it in Polter.", o.get("permissionDecisionReason").?.string);
}

test "2565 C6: a file nobody locked is let through: exit 0, nothing on stdout, and Polter was asked" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup(false);
    defer live.deinit();

    const ran = try runChild(live.path, live.token, free_payload);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    // It was in a position to deny: the question did arrive.
    try testing.expectEqual(@as(u32, 1), live.seen.asked.load(.acquire));
}

test "2565 C6: Polter not there: exit 0 and nothing on stdout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ran = try runChild("/tmp/pgg-no-such-socket.sock", "0" ** Server.token_len, locked_payload);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
}

test "2565 C6: no socket and no token in the environment: exit 0 and nothing on stdout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ran = try runChild(null, null, locked_payload);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
}

test "2565 C6: a token Polter does not know: exit 0, nothing on stdout, nobody asked" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup(false);
    defer live.deinit();

    const ran = try runChild(live.path, "0" ** Server.token_len, locked_payload);
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    try testing.expectEqual(@as(u32, 0), live.seen.asked.load(.acquire));
}

test "2565 C6: a payload that is not JSON, or has no path: exit 0, nothing on stdout, nobody asked" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup(false);
    defer live.deinit();

    const bad = try runChild(live.path, live.token, "this is not { json");
    try testing.expectEqual(@as(u8, 0), bad.code);
    try testing.expectEqual(@as(usize, 0), bad.stdout_bytes);
    // Reading the locked file is not writing it: not even asked.
    const read = try runChild(live.path, live.token,
        \\{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/w/a/docs/x.md"}}
    );
    try testing.expectEqual(@as(u8, 0), read.code);
    try testing.expectEqual(@as(usize, 0), read.stdout_bytes);
    const none = try runChild(live.path, live.token, "{\"tool_input\":{\"command\":\"ls\"}}");
    try testing.expectEqual(@as(u8, 0), none.code);
    try testing.expectEqual(@as(usize, 0), none.stdout_bytes);
    try testing.expectEqual(@as(u32, 0), live.seen.asked.load(.acquire));
}

test "2565 C6: a Polter that never answers is let through at the deadline: exit 0, nothing on stdout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var live: Live = undefined;
    try live.setup(true);
    defer live.deinit();

    const io = live.threaded.io();
    const t0: std.Io.Timestamp = .now(io, .awake);
    const ran = try runChild(live.path, live.token, locked_payload);
    const took_ms = t0.durationTo(.now(io, .awake)).toMilliseconds();
    try testing.expectEqual(@as(u8, 0), ran.code);
    try testing.expectEqual(@as(usize, 0), ran.stdout_bytes);
    // It was asked, and it was the deadline that ended the wait: not before
    // it, and not long after.
    try testing.expectEqual(@as(u32, 1), live.seen.asked.load(.acquire));
    try testing.expect(took_ms >= timeout_ms - 50);
    try testing.expect(took_ms < timeout_ms + 3000);
}
