//! JSON framing between the polter sidecar and Ghostty.
//!
//! One JSON object per line in each direction. Line framing rather than a
//! length prefix so the socket can be driven by hand with `nc` while
//! developing, which matters for something that otherwise only ever runs
//! with two agents and a terminal attached.
//!
//! Pure: bytes in, values out. See `docs/poltergeist/mcp.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const rpc = @import("rpc.zig");

pub const ParseError = error{
    /// The bytes are not a JSON object.
    Malformed,

    /// No `method`, or one this build does not know.
    UnknownMethod,

    /// A required parameter is missing or the wrong shape.
    BadParams,
} || Allocator.Error;

/// A request plus the arena owning any strings inside it.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    value: rpc.Request,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Read one request.
///
/// Terminal ids arrive either as a JSON number or as the `0x…` string the
/// host puts in `GHOSTTY_SURFACE_ID` (`src/Surface.zig`). Accepting both
/// matters: an agent reads that variable as text, and making it convert
/// first would turn every call site into a place to get it wrong.
pub fn parseRequest(alloc: Allocator, bytes: []const u8) ParseError!Parsed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    // The parse has to happen before the struct is built: Zig evaluates
    // fields in order, so copying the arena first would copy it empty and
    // every allocation would be lost with the local.
    const value = try parseRequestLeaky(arena.allocator(), bytes);
    return .{ .arena = arena, .value = value };
}

/// Same, but allocating from a caller-owned arena.
///
/// Used where the request must outlive the function that read it -- the
/// server hands it to another thread, and strings inside it have to stay
/// valid until that thread is finished with them.
pub fn parseRequestLeaky(aa: Allocator, bytes: []const u8) ParseError!rpc.Request {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        aa,
        bytes,
        .{},
    ) catch return error.Malformed;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.Malformed,
    };

    const method_val = obj.get("method") orelse return error.UnknownMethod;
    const method_name = switch (method_val) {
        .string => |s| s,
        else => return error.UnknownMethod,
    };

    const method = std.meta.stringToEnum(rpc.Method, method_name) orelse
        return error.UnknownMethod;

    const params: ?std.json.ObjectMap = switch (obj.get("params") orelse .null) {
        .object => |o| o,
        .null => null,
        else => return error.BadParams,
    };

    const value: rpc.Request = switch (method) {
        .me => .me,
        .terminal_list => .terminal_list,
        .notices => .notices,
        .session_recall => .session_recall,

        .notify_user => .{
            .notify_user = .{
                .reason = try requireString(aa, params, "reason"),
                .title = try requireString(aa, params, "title"),
                .body = (try optionalString(aa, params, "body")) orelse "",
                // Optional: a notice can be about the arrangement as a whole
                // rather than about one terminal.
                .id = requireId(params) catch 0,
            },
        },
        .group_members => .{ .group_members = .{
            .group = try requireString(aa, params, "group"),
        } },

        .group_set_brief => .{ .group_set_brief = .{
            .group = try requireString(aa, params, "group"),
            .text = try requireString(aa, params, "text"),
        } },

        .terminal_read => .{ .terminal_read = .{
            .id = try requireId(params),
            .lines = try optionalU16(params, "lines", 0),
        } },

        .terminal_send => .{ .terminal_send = .{
            .id = try requireId(params),
            .text = try requireString(aa, params, "text"),
            .submit = optionalBool(params, "submit", true),
        } },

        .clock_out => .{ .clock_out = .{
            .id = try requireId(params),
            .reason = (try optionalString(aa, params, "reason")) orelse "",
        } },

        .clock_in => .{ .clock_in = .{ .id = try requireId(params) } },
        .get_work_mode => .{ .get_work_mode = .{ .id = try requireId(params) } },

        .set_quiescence_threshold => .{ .set_quiescence_threshold = .{
            .id = try requireId(params),
            .ms = try requireU64(params, "ms"),
        } },

        .set_watch => .{ .set_watch = .{
            .id = try requireId(params),
            .watch = optionalBool(params, "watch", true),
        } },

        .set_work_mode => .{ .set_work_mode = .{
            .id = try requireId(params),
            .mode = try requireString(aa, params, "mode"),
        } },

        .skill_read => .{ .skill_read = .{
            .name = try requireString(aa, params, "name"),
        } },

        .group_create => .{ .group_create = .{
            .group = try requireString(aa, params, "group"),
        } },

        .group_destroy => .{ .group_destroy = .{
            .group = try requireString(aa, params, "group"),
        } },

        .group_add => .{ .group_add = .{
            .group = try requireString(aa, params, "group"),
            .id = try requireId(params),
            .history = try optionalHistory(params),
        } },

        .group_remove => .{ .group_remove = .{
            .group = try requireString(aa, params, "group"),
            .id = try requireId(params),
        } },

        .group_compact => .{ .group_compact = .{
            .group = try requireString(aa, params, "group"),
            .through = try requireU64(params, "through"),
            .summary = try requireString(aa, params, "summary"),
        } },

        .group_list => .group_list,

        .group_post => .{ .group_post = .{
            .group = try requireString(aa, params, "group"),
            .text = try requireString(aa, params, "text"),
        } },

        .group_read => .{ .group_read = .{
            .group = try requireString(aa, params, "group"),
            .since = try optionalU64(params, "since", 0),
        } },
    };

    return value;
}

fn requireId(params: ?std.json.ObjectMap) ParseError!Bus.Id {
    return requireIdNamed(params, "id");
}

fn requireIdNamed(params: ?std.json.ObjectMap, key: []const u8) ParseError!Bus.Id {
    const p = params orelse return error.BadParams;
    const v = p.get(key) orelse return error.BadParams;
    return switch (v) {
        .integer => |i| if (i < 0) error.BadParams else @intCast(i),

        // `0` as the base lets Zig read the `0x` prefix the host writes.
        .string => |s| std.fmt.parseUnsigned(Bus.Id, s, 0) catch error.BadParams,

        else => error.BadParams,
    };
}

fn requireString(
    aa: Allocator,
    params: ?std.json.ObjectMap,
    key: []const u8,
) ParseError![]const u8 {
    return (try optionalString(aa, params, key)) orelse error.BadParams;
}

fn optionalString(
    aa: Allocator,
    params: ?std.json.ObjectMap,
    key: []const u8,
) ParseError!?[]const u8 {
    const p = params orelse return null;
    const v = p.get(key) orelse return null;
    return switch (v) {
        .string => |s| try aa.dupe(u8, s),
        else => error.BadParams,
    };
}

fn requireU64(params: ?std.json.ObjectMap, key: []const u8) ParseError!u64 {
    const p = params orelse return error.BadParams;
    const v = p.get(key) orelse return error.BadParams;
    return switch (v) {
        .integer => |i| if (i < 0) error.BadParams else @intCast(i),
        else => error.BadParams,
    };
}

/// Defaults to showing nothing of what came before. Adding somebody to a
/// group should not hand them the backlog unless that was asked for.
fn optionalHistory(params: ?std.json.ObjectMap) ParseError!rpc.History {
    const p = params orelse return .none;
    const v = p.get("history") orelse return .none;
    return switch (v) {
        .string => |str| std.meta.stringToEnum(rpc.History, str) orelse
            error.BadParams,
        else => error.BadParams,
    };
}

fn optionalU64(
    params: ?std.json.ObjectMap,
    key: []const u8,
    default: u64,
) ParseError!u64 {
    const p = params orelse return default;
    const v = p.get(key) orelse return default;
    return switch (v) {
        .integer => |i| if (i < 0) error.BadParams else @intCast(i),
        else => error.BadParams,
    };
}

fn optionalU16(
    params: ?std.json.ObjectMap,
    key: []const u8,
    default: u16,
) ParseError!u16 {
    const p = params orelse return default;
    const v = p.get(key) orelse return default;
    return switch (v) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u16))
            error.BadParams
        else
            @intCast(i),
        else => error.BadParams,
    };
}

fn optionalBool(params: ?std.json.ObjectMap, key: []const u8, default: bool) bool {
    const p = params orelse return default;
    const v = p.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

/// What a terminal looks like in `terminal_list`.
///
/// Durations and bookkeeping, never screen contents. The supervisor calls
/// `terminal_read` if it wants to know what is actually on a screen, which
/// keeps both the reading and the judgement on its side.
pub const TerminalInfo = struct {
    id: Bus.Id,
    role: Bus.Role = .none,
    duty: Bus.Duty = .off,
    work_mode: Bus.WorkMode = .clock_off,
    watching: bool = false,

    /// Where it is working, and what its tab says.
    ///
    /// These two are here because they are the only things that can be put
    /// back for *any* terminal. What runs inside one may be an agent, or it
    /// may be somebody's shell with a build half finished in it -- so
    /// "resume the session" does not generalise, and "same directory, same
    /// tab name" does. They are also the only handle the supervisor has for
    /// telling last night's notes apart from what is on screen now.
    cwd: []const u8 = "",
    title: []const u8 = "",

    /// How long the screen has been unchanged, when anybody is measuring.
    ///
    /// Null for a terminal nobody is minding: it is not sampled at all, and
    /// reporting `0` would read as "busy this instant", which is the
    /// opposite of not knowing.
    quiet_ms: ?u64 = null,

    /// How many times the supervisor has been told this terminal is quiet
    /// since it last resumed. The clock-out skill counts against this.
    /// Null on the same terms as `quiet_ms`.
    rounds: ?u16 = null,
};

pub const Response = union(enum) {
    ok,
    me: TerminalInfo,
    terminals: []const TerminalInfo,
    text: []const u8,
    work_mode: Bus.WorkMode,
    skill: struct { name: []const u8, body: []const u8 },
    messages: []const rpc.ChatLine,
    groups: []const rpc.ChatGroupInfo,
    members: []const rpc.ChatMember,
    failed: struct { code: []const u8, message: []const u8 },
};

/// Write one response as a single line, newline included.
pub fn writeResponse(writer: *std.Io.Writer, res: Response) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{} };

    try s.beginObject();
    switch (res) {
        .ok => {
            try s.objectField("ok");
            try s.write(true);
        },
        .me => |info| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("me");
            try writeTerminal(&s, info);
        },
        .terminals => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("terminals");
            try s.beginArray();
            for (list) |info| try writeTerminal(&s, info);
            try s.endArray();
        },
        .text => |t| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("text");
            try s.write(t);
        },
        .work_mode => |m| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("work_mode");
            try s.write(@tagName(m));
        },
        .skill => |k| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("name");
            try s.write(k.name);
            try s.objectField("body");
            try s.write(k.body);
        },
        .members => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("members");
            try s.beginArray();
            for (list) |m| {
                try s.beginObject();
                try s.objectField("id");
                try writeId(&s, m.id);
                try s.objectField("title");
                try s.write(m.title);
                try s.endObject();
            }
            try s.endArray();
        },

        .groups => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("groups");
            try s.beginArray();
            for (list) |g| {
                try s.beginObject();
                try s.objectField("name");
                try s.write(g.name);

                // Only written when there is one, so a member's listing
                // does not carry an empty field that invites the question
                // of what it would have said.
                if (g.brief.len > 0) {
                    try s.objectField("brief");
                    try s.write(g.brief);
                }
                try s.endObject();
            }
            try s.endArray();
        },
        .messages => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("messages");
            try s.beginArray();
            for (list) |m| {
                try s.beginObject();
                try s.objectField("seq");
                try s.write(m.seq);
                try s.objectField("from");
                try writeId(&s, m.from);
                try s.objectField("author");
                try s.write(m.author);
                try s.objectField("at_ms");
                try s.write(m.at_ms);
                try s.objectField("summary");
                try s.write(m.summary);
                try s.objectField("text");
                try s.write(m.text);
                try s.endObject();
            }
            try s.endArray();
        },
        .failed => |f| {
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("code");
            try s.write(f.code);
            try s.objectField("message");
            try s.write(f.message);
        },
    }
    try s.endObject();
    try writer.writeByte('\n');
}

/// Ids go out as the same `0x…` text the host puts in the environment, so
/// what an agent reads from `GHOSTTY_SURFACE_ID` and what it sees here are
/// the same string. A JSON number would also lose precision in clients that
/// treat every number as a double.
fn writeId(s: *std.json.Stringify, id: Bus.Id) std.Io.Writer.Error!void {
    var buf: [18]u8 = undefined;
    try s.write(std.fmt.bufPrint(&buf, "0x{x:0>16}", .{id}) catch unreachable);
}

fn writeTerminal(s: *std.json.Stringify, info: TerminalInfo) std.Io.Writer.Error!void {
    try s.beginObject();

    try s.objectField("id");
    try writeId(s, info.id);

    try s.objectField("role");
    try s.write(@tagName(info.role));
    try s.objectField("duty");
    try s.write(@tagName(info.duty));
    try s.objectField("work_mode");
    try s.write(@tagName(info.work_mode));
    try s.objectField("watching");
    try s.write(info.watching);

    try s.objectField("cwd");
    try s.write(info.cwd);
    try s.objectField("title");
    try s.write(info.title);

    // Left out entirely rather than sent as null. A field that is absent
    // reads as "not measured"; a field that is present and null invites
    // the reader to treat it as a number it can compare against.
    if (info.quiet_ms) |ms| {
        try s.objectField("quiet_ms");
        try s.write(ms);
    }
    if (info.rounds) |r| {
        try s.objectField("rounds");
        try s.write(r);
    }

    try s.endObject();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn parse(bytes: []const u8) ParseError!Parsed {
    return parseRequest(testing.allocator, bytes);
}

test "a request with no params parses" {
    var p = try parse(
        \\{"method":"terminal_list"}
    );
    defer p.deinit();
    try testing.expect(p.value == .terminal_list);
}

test "an id may be a number" {
    var p = try parse(
        \\{"method":"clock_in","params":{"id":8738}}
    );
    defer p.deinit();
    try testing.expectEqual(@as(Bus.Id, 8738), p.value.clock_in.id);
}

test "an id may be the 0x string the host exports" {
    // This is what an agent reads out of GHOSTTY_SURFACE_ID, so it has to
    // work without the agent converting anything first.
    var p = try parse(
        \\{"method":"clock_in","params":{"id":"0x0000000000002222"}}
    );
    defer p.deinit();
    try testing.expectEqual(@as(Bus.Id, 0x2222), p.value.clock_in.id);
}

test "a negative id is refused rather than wrapped" {
    try testing.expectError(error.BadParams, parse(
        \\{"method":"clock_in","params":{"id":-1}}
    ));
}

test "terminal_send needs text" {
    try testing.expectError(error.BadParams, parse(
        \\{"method":"terminal_send","params":{"id":1}}
    ));

    var p = try parse(
        \\{"method":"terminal_send","params":{"id":1,"text":"继续"}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("继续", p.value.terminal_send.text);
    try testing.expect(p.value.terminal_send.submit);
}

test "submit defaults to true and can be turned off" {
    var p = try parse(
        \\{"method":"terminal_send","params":{"id":1,"text":"x","submit":false}}
    );
    defer p.deinit();
    try testing.expect(!p.value.terminal_send.submit);
}

test "optional fields fall back to their defaults" {
    var p = try parse(
        \\{"method":"terminal_read","params":{"id":1}}
    );
    defer p.deinit();
    try testing.expectEqual(@as(u16, 0), p.value.terminal_read.lines);

    var q = try parse(
        \\{"method":"terminal_read","params":{"id":1,"lines":80}}
    );
    defer q.deinit();
    try testing.expectEqual(@as(u16, 80), q.value.terminal_read.lines);
}

test "a lines count that cannot fit is refused" {
    try testing.expectError(error.BadParams, parse(
        \\{"method":"terminal_read","params":{"id":1,"lines":70000}}
    ));
}

test "unknown and missing methods are refused" {
    try testing.expectError(error.UnknownMethod, parse(
        \\{"method":"rm_rf"}
    ));
    try testing.expectError(error.UnknownMethod, parse(
        \\{"params":{}}
    ));
}

test "set_work_mode parses, and an unknown mode is refused where it is handled" {
    // This used to be refused outright: the ban on clocking off an
    // infinite-mode terminal depended on the mode being unreachable from
    // here. The supervisor arranges work now, and the rule moved into the
    // bus, which will not lift an infinite mode the user set.
    //
    // The wire layer's job is narrower: name and shape. Whether the string
    // is a mode this build knows is decided where the request is handled,
    // so that the answer can say what the choices are.
    var p = try parse(
        \\{"method":"set_work_mode","params":{"id":1,"mode":"infinite_directed"}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("infinite_directed", p.value.set_work_mode.mode);

    var nonsense = try parse(
        \\{"method":"set_work_mode","params":{"id":1,"mode":"whenever"}}
    );
    defer nonsense.deinit();
    try testing.expectEqualStrings("whenever", nonsense.value.set_work_mode.mode);
}

test "set_watch defaults to watching, because that is what it is for" {
    var on = try parse(
        \\{"method":"set_watch","params":{"id":1}}
    );
    defer on.deinit();
    try testing.expect(on.value.set_watch.watch);

    var off = try parse(
        \\{"method":"set_watch","params":{"id":1,"watch":false}}
    );
    defer off.deinit();
    try testing.expect(!off.value.set_watch.watch);
}

test "a wrongly typed optional field is refused, not ignored" {
    // Silently dropping a field the caller clearly meant to set would hide
    // the mistake from an agent that has no other way to notice it.
    try testing.expectError(error.BadParams, parse(
        \\{"method":"clock_out","params":{"id":1,"reason":42}}
    ));

    var p = try parse(
        \\{"method":"clock_out","params":{"id":1,"reason":"nothing left to do"}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("nothing left to do", p.value.clock_out.reason);
}

test "malformed input is refused rather than guessed at" {
    try testing.expectError(error.Malformed, parse("not json"));
    try testing.expectError(error.Malformed, parse("[1,2,3]"));
    try testing.expectError(error.Malformed, parse(""));
}

test "unknown extra fields are ignored" {
    var p = try parse(
        \\{"method":"me","params":{"unexpected":1},"id":99,"jsonrpc":"2.0"}
    );
    defer p.deinit();
    try testing.expect(p.value == .me);
}

test "a response carries ids as the same text the host exports" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try writeResponse(&w, .{ .me = .{
        .id = 0x2222,
        .role = .watched,
        .duty = .on,
        .work_mode = .clock_off,
        .quiet_ms = 1234,
        .watching = true,
        .rounds = 3,
    } });

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"0x0000000000002222\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"duty\":\"on\"") != null);
    try testing.expect(out[out.len - 1] == '\n');
}

test "a failure says what went wrong" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try writeResponse(&w, .{ .failed = .{
        .code = "WorkModeForbids",
        .message = rpc.errorMessage(error.WorkModeForbids),
    } });

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "infinite work mode") != null);
}

test "a response is one line" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const list = [_]TerminalInfo{
        .{ .id = 1, .role = .supervisor, .duty = .on, .work_mode = .clock_off, .quiet_ms = 0, .watching = false, .rounds = 0 },
        .{ .id = 2, .role = .watched, .duty = .off, .work_mode = .infinite_directed, .quiet_ms = 90_000, .watching = true, .rounds = 2 },
    };
    try writeResponse(&w, .{ .terminals = &list });

    const out = w.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

test "screen text goes out escaped, not raw" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Terminal contents contain anything at all, including quotes, newlines
    // and control bytes. If any of that reached the wire unescaped it would
    // break framing, and a line-framed protocol would resynchronise in the
    // middle of someone's screen.
    try writeResponse(&w, .{ .text = "a\"b\nc\x1b[0m" });

    const out = w.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);
}

test "an unwatched terminal is placed, but not measured" {
    // The two halves of the same rule: a terminal nobody is minding still
    // reports where it is and what its tab says, because those are what
    // put it back -- and reports no quiet time at all, because nothing is
    // sampling it. `"quiet_ms":0` would read as "busy this instant".
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const list = [_]TerminalInfo{
        .{
            .id = 0x11,
            .cwd = "/work/alpha",
            .title = "◑ colstat",
        },
        .{
            .id = 0x22,
            .role = .watched,
            .watching = true,
            .cwd = "/work/beta",
            .title = "◐ dedupe",
            .quiet_ms = 90_000,
            .rounds = 2,
        },
    };
    try writeResponse(&w, .{ .terminals = &list });
    const out = w.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "\"cwd\":\"/work/alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"title\":\"◑ colstat\"") != null);

    // One of the two is measured; the other says nothing rather than zero.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"quiet_ms\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"rounds\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"quiet_ms\":90000") != null);
}
