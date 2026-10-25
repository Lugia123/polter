const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const hook = @import("hook.zig");
const readline = @import("readline.zig");
const rpc = @import("../poltergeist/rpc.zig");
const transport = @import("../poltergeist/transport.zig");

const log = std.log.scoped(.hook_context);

/// The most of a hook's payload that is read. A compaction's payload is a
/// few hundred bytes; this only bounds what a runaway writer can make us
/// hold.
const max_stdin_bytes = 1024 * 1024;

/// The reader's fill window for the answer line.
///
/// ⚠️ **This was the ceiling and it is not any more** (task 2236). It read
/// with `takeDelimiter`, so a line longer than this failed -- and the one
/// part of the answer whose length is not ours is the terminal's own title,
/// which `set_surface_title` lets anybody set to any length. `ask` reads
/// the answer with `readline.readLine` now; this number is only how much is
/// held in memory at a time, and the real limit is `readline.max_reply`.
const max_reply = 64 * 1024;

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

/// The `hook-context` command puts a few lines from Polter into an agent
/// CLI's context around a compaction (task 1779). It is run by the CLI's
/// own hooks, which a role's adapter configures when it starts the CLI; it
/// is not run by hand.
///
///   polter +hook-context --cli claude-code PreCompact
///   polter +hook-context --cli claude-code SessionStart
///
/// It reads the hook's JSON payload on stdin, asks the terminal it runs in
/// (through `GHOSTTY_POLTER_SOCKET` and `GHOSTTY_POLTER_TOKEN`) what to
/// say, and prints it where the CLI reads it:
///
///   * `PreCompact`: plain text, which Claude Code adds to what the
///     summary is told to keep.
///   * `SessionStart` with `source: compact`: the
///     `hookSpecificOutput.additionalContext` the compacted session
///     starts with. Any other `source` prints nothing.
///
/// **The one Polter hook that writes to stdout, and it writes nothing at
/// all unless it has the whole answer.** `+hook` never writes there,
/// because Claude Code reads a hook's stdout as a decision; this one is
/// configured only on the two events whose stdout is context, and when
/// anything goes wrong -- no Polter, a refusal, a payload it cannot read --
/// it prints nothing and exits 0, so a compaction goes on exactly as it
/// would have without Polter. Failures go to Polter's log only.
pub fn run(alloc: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = global.io();

    const argv = hook.argsAfter(aa, "+hook-context") catch |err| {
        log.warn("+hook-context: could not read the command line err={t}", .{err});
        return 0;
    };
    var env = global.environMap() catch |err| {
        log.warn("+hook-context: could not read the environment err={t}", .{err});
        return 0;
    };
    defer env.deinit();

    // Read before anything else can fail, so the CLI's pipe is always
    // drained whatever happens next.
    var stdin: std.Io.File = .stdin();
    var in_buf: [16 * 1024]u8 = undefined;
    var reader = stdin.reader(io, &in_buf);
    const payload = reader.interface.allocRemaining(aa, .limited(max_stdin_bytes)) catch |err| {
        log.warn("+hook-context: could not read stdin err={t}", .{err});
        return 0;
    };

    const out = answer(
        aa,
        io,
        argv,
        payload,
        env.get("GHOSTTY_POLTER_SOCKET"),
        env.get("GHOSTTY_POLTER_TOKEN"),
    ) orelse return 0;
    std.Io.File.stdout().writeStreamingAll(io, out) catch |err| {
        log.warn("+hook-context: could not write the answer err={t}", .{err});
    };
    return 0;
}

/// What to print, or null to print nothing. Everything `run` does after
/// reading its input, so a test can drive the real path.
pub fn answer(
    aa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    payload: []const u8,
    socket_path: ?[]const u8,
    token: ?[]const u8,
) ?[]const u8 {
    const args = hook.parseArgs(argv) catch |err| {
        log.warn("+hook-context: bad arguments err={t}", .{err});
        return null;
    };
    const moment = momentOf(aa, args, payload) orelse return null;
    const text = ask(
        io,
        aa,
        socket_path orelse return null,
        token orelse return null,
        moment,
    ) catch |err| {
        log.warn("+hook-context: Polter did not answer err={t}", .{err});
        return null;
    };
    return render(aa, moment, text) catch null;
}

/// Which moment this hook is, or null when it is none Polter speaks at:
/// another CLI, another event, or a session that started for any reason
/// but a compaction. The adapter's matcher should already have kept those
/// away; this does not rely on it.
pub fn momentOf(aa: Allocator, args: hook.Args, payload: []const u8) ?rpc.HookMoment {
    if (!std.mem.eql(u8, args.cli, "claude-code")) return null;
    if (std.mem.eql(u8, args.event, "PreCompact")) return .before_compact;
    if (!std.mem.eql(u8, args.event, "SessionStart")) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, aa, payload, .{}) catch return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const source = switch (obj.get("source") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return if (std.mem.eql(u8, source, "compact")) .after_compact else null;
}

/// The bytes the CLI reads, for what Polter said.
pub fn render(aa: Allocator, moment: rpc.HookMoment, text: []const u8) ![]const u8 {
    switch (moment) {
        // Claude Code adds a PreCompact hook's stdout to the compaction's
        // instructions as it is.
        .before_compact => return std.fmt.allocPrint(aa, "{s}\n", .{text}),
        .after_compact => {
            var out: std.Io.Writer.Allocating = .init(aa);
            var s: std.json.Stringify = .{ .writer = &out.writer };
            try s.beginObject();
            try s.objectField("hookSpecificOutput");
            try s.beginObject();
            try s.objectField("hookEventName");
            try s.write("SessionStart");
            try s.objectField("additionalContext");
            try s.write(text);
            try s.endObject();
            try s.endObject();
            try out.writer.writeByte('\n');
            return out.written();
        },
    }
}

/// Ask the terminal whose token this is what to say.
fn ask(
    io: std.Io,
    aa: Allocator,
    socket_path: []const u8,
    token: []const u8,
    moment: rpc.HookMoment,
) ![]const u8 {
    const conn = try transport.connect(io, socket_path);
    defer conn.close(io);

    const read_buf = try aa.alloc(u8, max_reply);
    var write_buf: [1024]u8 = undefined;
    var reader = conn.reader(io, read_buf);
    var writer = conn.writer(io, &write_buf);
    const w = &writer.interface;

    // As `hook.deliver` does it, and for its reason (task 1736): a refusal
    // can be waiting before the token is written.
    //
    // `takeDelimiter` here is on purpose, and `hook.zig`'s note on
    // `max_reply` is where the reasoning and the measurement live: an
    // `auth` answer is one of `Server.zig`'s fixed sentences, about 100
    // bytes at the most. The read below is the one that had to change.
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

    try w.print("{{\"method\":\"hook_context\",\"params\":{{\"moment\":\"{t}\"}}}}\n", .{moment});
    try w.flush();

    // **The one answer in this file whose length is not ours** (task 2236),
    // so it is read with the shared reader rather than with `takeDelimiter`
    // into `max_reply`.
    //
    // The text is `rpc.hookContextText`: fixed wording, this terminal's id,
    // **its title**, and its group names. The groups are capped (`Chat`
    // allows 48 bytes a name and 32 groups, so under 4 KiB even written
    // twice), and for a long time that made 64 KiB look like plenty. What
    // it missed is the title: the OSC 0/2 path truncates at 1024 bytes, but
    // `set_surface_title` -- which any caller may send, and which
    // `terminal_action` will carry -- goes through `apprt.Title.replace`
    // and is not truncated at all. A title set that way can be as long as
    // one request, so the answer can pass `max_reply`, and past it the read
    // used to fail *after* the reply was the only thing on the wire -- a
    // compaction with no context, and nothing anywhere saying why.
    //
    // Past `readline.max_reply` the answer is discarded to its newline and
    // this fails for this call only; the next hook gets a clean stream.
    var reply_buf: std.Io.Writer.Allocating = .init(aa);
    defer reply_buf.deinit();
    const reply = readline.readLine(&reader.interface, &reply_buf, readline.max_reply) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.LineTooLong, error.ReadFailed, error.OutOfMemory => return error.Refused,
    };
    return textOf(aa, reply) orelse {
        log.warn("+hook-context: refused: {s}", .{reply[0..@min(reply.len, 200)]});
        return error.Refused;
    };
}

/// The `text` of an `{"ok":true,"text":…}` reply, or null for anything
/// else -- a refusal is printed as nothing, never as its message.
pub fn textOf(aa: Allocator, reply: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, aa, reply, .{}) catch return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    switch (obj.get("ok") orelse return null) {
        .bool => |b| if (!b) return null,
        else => return null,
    }
    const text = switch (obj.get("text") orelse return null) {
        .string => |t| t,
        else => return null,
    };
    if (text.len == 0) return null;
    return text;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Server = @import("../poltergeist/Server.zig");

fn argsOf(cli: []const u8, event: []const u8) hook.Args {
    return .{ .cli = cli, .event = event };
}

test "1779: +hook-context speaks before a compaction, and after one only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const before = momentOf(aa, argsOf("claude-code", "PreCompact"), "{\"trigger\":\"auto\"}");
    try testing.expectEqual(@as(?rpc.HookMoment, .before_compact), before);

    const after = momentOf(aa, argsOf("claude-code", "SessionStart"), "{\"source\":\"compact\"}");
    try testing.expectEqual(@as(?rpc.HookMoment, .after_compact), after);

    // A session started for any other reason is not one to speak into.
    for ([_][]const u8{ "startup", "resume", "clear" }) |source| {
        const payload = try std.fmt.allocPrint(aa, "{{\"source\":\"{s}\"}}", .{source});
        const other = momentOf(aa, argsOf("claude-code", "SessionStart"), payload);
        try testing.expectEqual(@as(?rpc.HookMoment, null), other);
    }
    const no_source = momentOf(aa, argsOf("claude-code", "SessionStart"), "{}");
    try testing.expectEqual(@as(?rpc.HookMoment, null), no_source);
    const not_json = momentOf(aa, argsOf("claude-code", "SessionStart"), "not json");
    try testing.expectEqual(@as(?rpc.HookMoment, null), not_json);

    // Nor another CLI, nor another event.
    const codex = momentOf(aa, argsOf("codex", "PreCompact"), "{}");
    try testing.expectEqual(@as(?rpc.HookMoment, null), codex);
    const stop = momentOf(aa, argsOf("claude-code", "Stop"), "{}");
    try testing.expectEqual(@as(?rpc.HookMoment, null), stop);
}

test "1779: after a compaction the answer is Claude Code's additionalContext, before one it is the text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const after = try render(aa, .after_compact, "say \"this\"\nand that");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, after, .{});
    const out = parsed.object.get("hookSpecificOutput").?.object;
    const event_name = out.get("hookEventName").?.string;
    try testing.expectEqualStrings("SessionStart", event_name);
    const context = out.get("additionalContext").?.string;
    try testing.expectEqualStrings("say \"this\"\nand that", context);

    const before = try render(aa, .before_compact, "keep this");
    try testing.expectEqualStrings("keep this\n", before);
}

test "1779: only an ok reply with text is printed; a refusal is nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ok = textOf(aa, "{\"ok\":true,\"text\":\"hello\"}");
    try testing.expectEqualStrings("hello", ok.?);
    const refused = textOf(aa, "{\"ok\":false,\"error\":{\"code\":\"NotATerminal\",\"message\":\"no\"}}");
    try testing.expect(refused == null);
    const empty = textOf(aa, "{\"ok\":true,\"text\":\"\"}");
    try testing.expect(empty == null);
    const no_text = textOf(aa, "{\"ok\":true}");
    try testing.expect(no_text == null);
}

/// A Polter that answers `hook_context` with `said`, and anything else
/// with a refusal.
const Answers = struct {
    io: std.Io,
    said: []const u8,
    moment: std.atomic.Value(u8) = .init(0xff),

    fn submit(ctx: *anyopaque, pending: *Server.Pending) void {
        const self: *Answers = @ptrCast(@alignCast(ctx));
        defer pending.release();
        switch (pending.request) {
            .hook_context => |p| {
                self.moment.store(@intFromEnum(p.moment), .release);
                pending.complete(self.io, .{ .text = self.said });
            },
            else => pending.complete(self.io, .{ .failed = .{ .code = "Nope", .message = "not this" } }),
        }
    }
};

test "1779: +hook-context asks the terminal it runs in, and prints what it says" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var answers: Answers = .{ .io = io, .said = "[From Polter] read task_list" };
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/pghc-{x}.sock", .{&raw}, 0);
    defer alloc.free(path);
    var server: Server = try .init(alloc, io, path, .{
        .ctx = &answers,
        .func = Answers.submit,
    }, Server.default_max_connections);
    defer server.deinit();
    try server.start();
    const token = try server.issueToken(0x2222);

    const after = answer(aa, io, &.{ "--cli", "claude-code", "SessionStart" }, "{\"source\":\"compact\"}", path, token);
    try testing.expectEqual(@intFromEnum(rpc.HookMoment.after_compact), answers.moment.load(.acquire));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, after.?, .{});
    const context = parsed.object.get("hookSpecificOutput").?.object.get("additionalContext").?.string;
    try testing.expectEqualStrings("[From Polter] read task_list", context);

    const before = answer(aa, io, &.{ "--cli", "claude-code", "PreCompact" }, "{\"trigger\":\"manual\"}", path, token);
    try testing.expectEqual(@intFromEnum(rpc.HookMoment.before_compact), answers.moment.load(.acquire));
    try testing.expectEqualStrings("[From Polter] read task_list\n", before.?);

    // A session that started for another reason asks nothing.
    answers.moment.store(0xff, .release);
    const startup = answer(aa, io, &.{ "--cli", "claude-code", "SessionStart" }, "{\"source\":\"startup\"}", path, token);
    try testing.expect(startup == null);
    try testing.expectEqual(@as(u8, 0xff), answers.moment.load(.acquire));
}

test "1779: +hook-context with no Polter, or a token it does not know, prints nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const argv: []const []const u8 = &.{ "--cli", "claude-code", "PreCompact" };

    const no_socket = answer(aa, io, argv, "{}", "/tmp/pghc-no-such-socket.sock", "0" ** Server.token_len);
    try testing.expect(no_socket == null);
    const no_env = answer(aa, io, argv, "{}", null, null);
    try testing.expect(no_env == null);

    var answers: Answers = .{ .io = io, .said = "x" };
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/pghc-{x}.sock", .{&raw}, 0);
    defer alloc.free(path);
    var server: Server = try .init(alloc, io, path, .{
        .ctx = &answers,
        .func = Answers.submit,
    }, Server.default_max_connections);
    defer server.deinit();
    try server.start();
    _ = try server.issueToken(0x2222);

    const wrong_token = answer(aa, io, argv, "{}", path, "0" ** Server.token_len);
    try testing.expect(wrong_token == null);
    try testing.expectEqual(@as(u8, 0xff), answers.moment.load(.acquire));
}

// -- task 2236: the answer is not bounded by a buffer -----------------------

// The answer is mostly Polter's own wording, and the one part of it whose
// length is not Polter's is the terminal's title. **`set_surface_title` does
// not truncate**: the OSC 0/2 path stops at 1024 bytes
// (`stream_terminal.zig`), but this one goes through `apprt.Title.replace`
// and keeps whatever it is handed, and `terminal_action` will carry it. So a
// title can be as long as one request, and this is what that makes of the
// answer.
//
// The read used to be `takeDelimiter` into `max_reply` (64 KiB), and past
// that the reply -- which is the only thing on the wire -- failed to be
// read. The hook then printed nothing, so a compaction went ahead with no
// context and nothing anywhere said why.
test "2236: an answer longer than the read buffer is read, and its text comes out whole" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Longer than `max_reply`, and longer than the *old* whole limit: this
    // is the case that used to be a failure rather than a shorter answer.
    const said = try std.fmt.allocPrint(aa, "[From Polter] {s}", .{"t" ** (max_reply + 4096)});

    var answers: Answers = .{ .io = io, .said = said };
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/pghc-long-{x}.sock", .{&raw}, 0);
    defer alloc.free(path);
    var server: Server = try .init(alloc, io, path, .{
        .ctx = &answers,
        .func = Answers.submit,
    }, Server.default_max_connections);
    defer server.deinit();
    try server.start();
    const token = try server.issueToken(0x2222);

    const before = answer(aa, io, &.{ "--cli", "claude-code", "PreCompact" }, "{\"trigger\":\"manual\"}", path, token);

    // **The whole text, measured here rather than trusted.** `render` adds
    // a newline for this moment, so the answer is the text plus one byte --
    // and an answer that had been cut anywhere would be shorter.
    const got = before orelse {
        std.debug.print(
            "\n+hook-context printed nothing for a {d}-byte answer: the reply " ++
                "was not read at all, which is what a full buffer used to do.\n",
            .{said.len},
        );
        return error.NothingPrinted;
    };
    try testing.expectEqual(said.len + 1, got.len);
    try testing.expectEqualStrings(said, got[0..said.len]);
}
