const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const net = std.Io.net;

const log = std.log.scoped(.mcp);

/// MCP protocol revision this speaks. Sent back in `initialize`.
const protocol_version = "2024-11-05";

/// Longest reply we will read from the host. Screen dumps are the large
/// case, and the host caps them below this.
const max_line = 256 * 1024;

/// Longest request the host will read. Kept in step with
/// `Server.max_request_bytes`; a mismatch means the host silently drops the
/// connection on a request the sidecar thought was fine.
const max_request_bytes = 64 * 1024;

pub const Options = struct {
    /// Socket to reach Ghostty on. Defaults to `GHOSTTY_POLTER_SOCKET`.
    socket: ?[]const u8 = null,

    /// Token identifying this terminal. Defaults to `GHOSTTY_POLTER_TOKEN`.
    token: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `mcp` command runs an MCP server that lets an agent see and
/// steer the other terminals a Poltergeist supervisor is watching.
///
/// It is not run by hand. Point an MCP client at it:
///
///   {"command": "polter", "args": ["+mcp"]}
///
/// It finds the terminal it belongs to through `GHOSTTY_POLTER_SOCKET` and
/// `GHOSTTY_POLTER_TOKEN`, which Ghostty puts in every terminal's
/// environment when `poltergeist-mcp` is enabled. Identity comes from that
/// token alone -- an agent cannot ask to be treated as a different terminal.
///
/// Flags:
///
///   * `--socket`: override the socket path.
///   * `--token`: override the token.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const io = global.io();

    var env = try global.environMap();
    defer env.deinit();

    const socket_path = opts.socket orelse
        env.get("GHOSTTY_POLTER_SOCKET") orelse
        {
            log.err("no socket: is `poltergeist-mcp` enabled, and is this running inside Ghostty?", .{});
            return 1;
        };

    const token = opts.token orelse
        env.get("GHOSTTY_POLTER_TOKEN") orelse
        {
            log.err("no token: is `poltergeist-mcp` enabled, and is this running inside Ghostty?", .{});
            return 1;
        };

    var host: Host = try .connect(alloc, io, socket_path, token);
    defer host.deinit();

    return serve(alloc, io, &host);
}

/// The connection back to Ghostty.
const Host = struct {
    alloc: Allocator,
    io: std.Io,
    stream: net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,

    fn connect(
        alloc: Allocator,
        io: std.Io,
        path: []const u8,
        token: []const u8,
    ) !Host {
        const addr = try net.UnixAddress.init(path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);

        const read_buf = try alloc.alloc(u8, max_line);
        errdefer alloc.free(read_buf);
        const write_buf = try alloc.alloc(u8, max_line);
        errdefer alloc.free(write_buf);

        var self: Host = .{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
        };

        // Prove who we are before anything else. The host closes the
        // connection if this does not check out.
        try self.writer.interface.print(
            \\{{"method":"auth","params":{{"token":"{s}"}}}}
        ++ "\n", .{token});
        try self.writer.interface.flush();

        const reply = (try self.reader.interface.takeDelimiter('\n')) orelse
            return error.EndOfStream;
        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
            log.err("ghostty refused this token", .{});
            return error.AuthFailed;
        }

        return self;
    }

    fn deinit(self: *Host) void {
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
        self.* = undefined;
    }

    /// Send one request line and return the reply line. The reply borrows
    /// the read buffer and is valid until the next call.
    fn call(self: *Host, line: []const u8) ![]const u8 {
        try self.writer.interface.writeAll(line);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
        // `takeDelimiter` consumes the newline; the exclusive form leaves it
        // and every later call returns an empty slice forever.
        return (try self.reader.interface.takeDelimiter('\n')) orelse
            error.EndOfStream;
    }
};

/// Every tool this exposes, with the request it maps to.
///
/// The list is deliberately short and matches `src/poltergeist/rpc.zig`
/// exactly. In particular there is no tool for changing a work mode and
/// none for answering another agent's permission prompt; see that file for
/// why neither will be added.
const tools = [_]Tool{
    .{
        .name = "me",
        .description = "Which terminal this agent is running in, and whether it is supervising or supervised.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "terminal_list",
        .description = "Every terminal Poltergeist knows about: how long each screen has been unchanged, and whether it is on duty. Durations only -- call terminal_read to see what is actually on one.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notices",
        .description = "What has happened that you have not been shown yet: which terminals went quiet and for how long, and which came back to work. Reading clears them, so what comes back will not come back again. You are also handed this on a timer; call it yourself whenever you finish something, rather than waiting to be interrupted. An empty answer means nothing is waiting. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notify_user",
        .description = "Ask for the person to be told something. Use `reason: authorisation` when a terminal is stopped on a permission prompt -- nobody may answer those for it, so those go out at any hour. Use `reason: scheduling` for questions you could answer yourself (keep going, change tack, give up); those are held back during the hours the user set aside, and handed back to you to decide. **Read the reply**: it says whether the message actually went anywhere. If it did not, do not sit waiting for an answer. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"reason":{"type":"string","enum":["authorisation","scheduling"]},"title":{"type":"string"},"body":{"type":"string"},"id":{"type":"string","description":"The terminal this is about, if it is about one"}},"required":["reason","title"]}
        ,
    },
    .{
        .name = "session_recall",
        .description = "What last night's arrangement was, written down before the restart: the groups, what each was for, and for every terminal where it was working and what it was called. Read this first after a restart, then look at what is open now and decide for yourself which is which -- nothing here does that for you, and a wrong guess would attach one terminal's supervision to another without saying so. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "group_set_brief",
        .description = "Say what a group is for, in your own words. Write this right after creating a group, while you still know why you made it -- in eight hours group_list will show you a name you no longer recognise, and that is exactly when you have to decide whether it still needs watching. Only you and the person at the keyboard see it; the members do not. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"text":{"type":"string"}},"required":["group","text"]}
        ,
    },
    .{
        .name = "group_members",
        .description = "Who is in a group, and what each terminal is currently called. Useful before asking somebody to do something: a group where the terminal you want is not a member cannot reach it.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"}},"required":["group"]}
        ,
    },
    .{
        .name = "terminal_read",
        .description = "Read the visible screen of another terminal. Scrollback is not available. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Terminal id, as shown by terminal_list"}},"required":["id"]}
        ,
    },
    .{
        .name = "terminal_send",
        .description = "Type into another terminal, exactly as the user would. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"},"submit":{"type":"boolean","description":"Press return afterwards; defaults to true"}},"required":["id","text"]}
        ,
    },
    .{
        .name = "clock_out",
        .description = "Mark a terminal as done for the day, so its going quiet stops being reported. Refused for terminals in an infinite work mode. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"reason":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "clock_in",
        .description = "Put a terminal back on duty. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "get_work_mode",
        .description = "What work mode a terminal runs under. Only the user can change it. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "skill_read",
        .description = "Read one of Poltergeist's skills: the text describing how to supervise, how to read a terminal, or how a particular work mode should be handled. Start with `supervising`.",
        .schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"supervising, reading-a-terminal, mode-clock-out, mode-infinite-directed or mode-infinite-sequential"}},"required":["name"]}
        ,
    },
    .{
        .name = "group_create",
        .description = "Make a group for terminals to talk in. Supervisor only: who talks to whom is yours to arrange.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string","description":"Lowercase letters, digits and dashes"}},"required":["group"]}
        ,
    },
    .{
        .name = "group_destroy",
        .description = "Take a group away, and everything said in it. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"}},"required":["group"]}
        ,
    },
    .{
        .name = "group_add",
        .description = "Put a terminal in a group. Choose whether it sees what was said before it arrived: `none` starts the conversation for it now, `all` hands it everything still in the log. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"id":{"type":"string"},"history":{"type":"string","enum":["none","all"],"description":"Defaults to none"}},"required":["group","id"]}
        ,
    },
    .{
        .name = "group_remove",
        .description = "Take a terminal out of a group. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"id":{"type":"string"}},"required":["group","id"]}
        ,
    },
    .{
        .name = "group_compact",
        .description = "Replace everything up to a given seq with one summary you write, the way /compact shortens a conversation. Use it when a group's history has grown longer than it is worth. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"through":{"type":"integer","description":"Replace messages up to and including this seq"},"summary":{"type":"string","description":"What those messages amounted to"}},"required":["group","through","summary"]}
        ,
    },
    .{
        .name = "group_list",
        .description = "Which groups you are in.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "group_post",
        .description = "Say something to a group you are in. The others are told they have a message; they read it when they choose to.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"text":{"type":"string"}},"required":["group","text"]}
        ,
    },
    .{
        .name = "group_read",
        .description = "Read messages you have not seen in a group. Pass the last seq you saw to pick up from there. A message marked `summary` stands in for older ones that were compacted away.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"since":{"type":"integer"}},"required":["group"]}
        ,
    },
    .{
        .name = "set_quiescence_threshold",
        .description = "How long a terminal must be still before it is reported. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"ms":{"type":"integer"}},"required":["id","ms"]}
        ,
    },
    .{
        .name = "set_watch",
        .description = "Put a terminal under your supervision, or take it out again. " ++
            "A terminal you watch is one you can read and type into, so this is the tool " ++
            "that decides your reach. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"watch":{"type":"boolean","description":"Defaults to true"}},"required":["id"]}
        ,
    },
    .{
        .name = "set_work_mode",
        .description = "Change what a terminal's work mode asks of it: clock_off, " ++
            "infinite_directed or infinite_sequential. You may put a terminal into an " ++
            "infinite mode and move it between them. An infinite mode the *user* set is a " ++
            "standing instruction and only they can lift it. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"mode":{"type":"string","enum":["clock_off","infinite_directed","infinite_sequential"]}},"required":["id","mode"]}
        ,
    },
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

fn serve(alloc: Allocator, io: std.Io, host: *Host) !u8 {
    var in_buf: [max_line]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;

    var stdin: std.Io.File = .stdin();
    var stdout: std.Io.File = .stdout();
    var reader = stdin.reader(io, &in_buf);
    var writer = stdout.writer(io, &out_buf);

    while (true) {
        // A null line is end of stdin: the client closed, so we are done.
        const line = (try reader.interface.takeDelimiter('\n')) orelse return 0;
        if (line.len == 0) continue;

        handleOne(alloc, host, &writer.interface, line) catch |err| {
            log.warn("mcp: could not handle a message err={}", .{err});
        };
    }
}

fn handleOne(
    alloc: Allocator,
    host: *Host,
    out: *std.Io.Writer,
    line: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const msg = std.json.parseFromSliceLeaky(std.json.Value, aa, line, .{}) catch {
        // No id to answer against, so there is nobody to tell.
        return;
    };
    const obj = switch (msg) {
        .object => |o| o,
        else => return,
    };

    const method = switch (obj.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };

    // A notification has no id and takes no reply. `notifications/initialized`
    // is the common one, and answering it is a protocol error.
    const id = obj.get("id") orelse return;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeResult(out, id, aa,
            \\{"protocolVersion":"
        ++ protocol_version ++
            \\","capabilities":{"tools":{}},"serverInfo":{"name":"poltergeist","version":"0"}}
        );
        return;
    }

    // MCP requires a server to answer ping. Falling through to "method not
    // found" makes a client treat a healthy server as broken.
    if (std.mem.eql(u8, method, "ping")) {
        try writeResult(out, id, aa, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        var body: std.Io.Writer.Allocating = .init(aa);
        defer body.deinit();
        const w = &body.writer;

        try w.writeAll("{\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                \\{{"name":"{s}","description":{f},"inputSchema":{s}}}
            , .{ t.name, std.json.fmt(t.description, .{}), t.schema });
        }
        try w.writeAll("]}");

        try writeResult(out, id, aa, body.written());
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| o,
            else => return writeToolError(out, id, aa, "call had no params"),
        };
        const name = switch (params.get("name") orelse .null) {
            .string => |s| s,
            else => return writeToolError(out, id, aa, "call had no tool name"),
        };

        var known = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, name)) known = true;
        }
        if (!known) return writeToolError(out, id, aa, "no such tool");

        // The host speaks the same method names, so the call is a rewrap
        // rather than a translation.
        const arguments: []const u8 = if (params.get("arguments")) |a|
            try std.fmt.allocPrint(aa, "{f}", .{std.json.fmt(a, .{})})
        else
            "{}";

        const request = try std.fmt.allocPrint(aa,
            \\{{"method":"{s}","params":{s}}}
        , .{ name, arguments });

        // The host reads a bounded line. Sending more would have it drop
        // the connection with nothing said, so refuse here where there is
        // still somebody to tell.
        if (request.len + 1 > max_request_bytes) {
            return writeToolError(out, id, aa, "that call is too large to send");
        }

        const reply = host.call(request) catch |err| {
            return writeToolError(out, id, aa, switch (err) {
                error.EndOfStream => "ghostty closed the connection",
                else => "could not reach ghostty",
            });
        };

        // Pass the host's answer through as text. Agents read this, and the
        // host already phrases its failures for them.
        try writeResult(out, id, aa, try std.fmt.allocPrint(aa,
            \\{{"content":[{{"type":"text","text":{f}}}],"isError":{}}}
        , .{
            std.json.fmt(reply, .{}),
            std.mem.indexOf(u8, reply, "\"ok\":false") != null,
        }));
        return;
    }

    try writeError(out, id, aa, -32601, "method not found");
}

fn writeResult(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    result: []const u8,
) !void {
    _ = aa;
    try out.print(
        \\{{"jsonrpc":"2.0","id":{f},"result":{s}}}
    ++ "\n", .{ std.json.fmt(id, .{}), result });
    try out.flush();
}

fn writeError(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    code: i32,
    message: []const u8,
) !void {
    _ = aa;
    try out.print(
        \\{{"jsonrpc":"2.0","id":{f},"error":{{"code":{d},"message":{f}}}}}
    ++ "\n", .{ std.json.fmt(id, .{}), code, std.json.fmt(message, .{}) });
    try out.flush();
}

/// A tool failure is a *successful* JSON-RPC reply carrying `isError`, not a
/// protocol error. Getting this backwards makes clients treat a refused
/// action as a broken server.
fn writeToolError(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    message: []const u8,
) !void {
    const body = try std.fmt.allocPrint(aa,
        \\{{"content":[{{"type":"text","text":{f}}}],"isError":true}}
    , .{std.json.fmt(message, .{})});
    try writeResult(out, id, aa, body);
}

test {
    // Nothing here runs without a socket and an agent on the other end, so
    // without this the whole file would go unchecked.
    std.testing.refAllDecls(@This());
}

test "the tool list matches the host's method names" {
    const rpc = @import("../poltergeist/rpc.zig");

    // A tool the host does not know is a tool that fails at the worst
    // possible moment: after an agent has decided to use it.
    for (tools) |t| {
        try std.testing.expect(
            std.meta.stringToEnum(rpc.Method, t.name) != null,
        );
    }

    // And every host method is offered, so nothing is silently unreachable.
    for (std.enums.values(rpc.Method)) |m| {
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, @tagName(m))) found = true;
        }
        try std.testing.expect(found);
    }
}

test "no tool offers to answer another agent's prompt" {
    // `terminal_send` is a general text primitive and that is all there is.
    // A dedicated approve/deny tool would make it one step to hand away
    // another agent's safety model (R2), so there is none -- and this is
    // the test that should object if one appears.
    //
    // Changing a work mode *is* offered now: arranging work is the
    // supervisor's job. What protects the ban on clocking off an
    // infinite-mode terminal moved into the bus, which refuses to lift an
    // infinite mode the user set. See `Bus.setWorkMode`.
    for (tools) |t| {
        try std.testing.expect(std.mem.indexOf(u8, t.name, "approve") == null);
        try std.testing.expect(std.mem.indexOf(u8, t.name, "permission") == null);
        try std.testing.expect(std.mem.indexOf(u8, t.name, "deny") == null);
    }
}

test "the tools that decide reach say so in their own description" {
    // Somebody reading the tool list should not have to infer that watching
    // a terminal is what makes it readable.
    for (tools) |t| {
        if (!std.mem.eql(u8, t.name, "set_watch")) continue;
        try std.testing.expect(std.mem.indexOf(u8, t.description, "read") != null);
        return;
    }
    return error.ToolMissing;
}

test "every tool describes itself and carries a schema" {
    for (tools) |t| {
        try std.testing.expect(t.name.len > 0);
        try std.testing.expect(t.description.len > 20);
        try std.testing.expect(std.mem.startsWith(u8, t.schema, "{\"type\":\"object\""));
    }
}
