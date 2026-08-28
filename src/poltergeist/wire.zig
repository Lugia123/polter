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
const Plugin = @import("Plugin.zig");
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

        .set_quiescence_threshold => .{ .set_quiescence_threshold = .{
            .id = try requireId(params),
            .ms = try requireU64(params, "ms"),
        } },

        .set_watch => .{ .set_watch = .{
            .id = try requireId(params),
            .watch = optionalBool(params, "watch", true),
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

        .stand_down => .stand_down,
        .become_supervisor => .become_supervisor,
        .terminal_actions => .terminal_actions,

        .config_get => .{ .config_get = .{
            .key = (try optionalString(aa, params, "key")) orelse "",
        } },

        .terminal_open => .{ .terminal_open = .{
            .cwd = (try optionalString(aa, params, "cwd")) orelse "",
            .watch = optionalBool(params, "watch", false),
        } },

        .terminal_action => .{ .terminal_action = .{
            .id = try requireId(params),
            .action = try requireString(aa, params, "action"),
        } },

        .group_history => .{ .group_history = .{
            .group = try requireString(aa, params, "group"),
            .before_seq = try optionalU64(params, "before_seq", 0),
            .limit = try optionalU64(params, "limit", 0),
        } },

        .plugin_list => .{ .plugin_list = .{
            .key = (try optionalString(aa, params, "key")) orelse "",
        } },

        .plugin_configure => .{ .plugin_configure = .{
            .key = try requireString(aa, params, "key"),
            .enable = optionalBoolOrNull(params, "enabled"),
            .params = try optionalParams(aa, params, "params"),
        } },

        .plugin_test => .{ .plugin_test = .{
            .key = try requireString(aa, params, "key"),
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

/// `null` when the field is absent, so "not mentioned" and "set to false"
/// stay different things -- a configure that only changes a parameter
/// must not read as a request to switch the plugin off.
fn optionalBoolOrNull(params: ?std.json.ObjectMap, key: []const u8) ?bool {
    const p = params orelse return null;
    const v = p.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,

        // Not a bool is not a request either. Reading `"true"` as true
        // would have a typo switch something on.
        else => null,
    };
}

/// The `params` object as name/value pairs.
///
/// Strings only, and a non-string is `BadParams` rather than skipped: a
/// caller that wrote a number meant something by it, and dropping the
/// field silently would have it believe a value was set.
fn optionalParams(
    aa: Allocator,
    params: ?std.json.ObjectMap,
    key: []const u8,
) ParseError![]const Plugin.Param {
    const p = params orelse return &.{};
    const v = p.get(key) orelse return &.{};
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadParams,
    };

    var out: std.ArrayListUnmanaged(Plugin.Param) = .empty;
    var it = obj.iterator();
    while (it.next()) |kv| {
        const value = switch (kv.value_ptr.*) {
            .string => |str| str,
            else => return error.BadParams,
        };
        try out.append(aa, .{
            .name = try aa.dupe(u8, kv.key_ptr.*),
            .value = try aa.dupe(u8, value),
        });
    }
    return out.items;
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

    /// Whether the user is holding this terminal to its work, so it may
    /// not be clocked off.
    held: bool = false,

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
    skill: struct { name: []const u8, body: []const u8 },
    messages: struct {
        lines: []const rpc.ChatLine,

        /// Whether the reply was cut short by the size budget.
        ///
        /// Without this a capped batch is indistinguishable from the end
        /// of the conversation, and a reader stops one screenful in
        /// believing it has everything -- which is exactly what happened.
        more: bool = false,
    },
    groups: []const rpc.ChatGroupInfo,
    members: []const rpc.ChatMember,
    plugins: []const rpc.PluginView,
    actions: []const rpc.actions.Entry,
    opened: struct {
        /// Null when the runtime has not made it yet. Not an error: the tab
        /// is coming and `terminal_list` will have it.
        id: ?Bus.Id,
        watching: bool,
    },
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
        .messages => |v| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("more");
            try s.write(v.more);
            try s.objectField("messages");
            try s.beginArray();
            for (v.lines) |m| {
                try s.beginObject();
                try s.objectField("seq");
                try s.write(m.seq);

                // Both readings of a conversation come out in this one
                // shape, so a reader needs one parser: `group_read` fills
                // in `seq` and `group_history` fills in `log_seq`, and
                // each writes zero where it has nothing to say.
                try s.objectField("log_seq");
                try s.write(m.log_seq);
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
        .plugins => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("plugins");
            try s.beginArray();
            for (list) |v| try writePlugin(&s, v);
            try s.endArray();
        },
        .opened => |v| {
            try s.objectField("ok");
            try s.write(true);

            // Present only when there is one. An `id: null` would read as
            // "the terminal has no id", when what happened is that it does
            // not exist yet.
            if (v.id) |id| {
                try s.objectField("id");
                try writeId(&s, id);
            }
            try s.objectField("watching");
            try s.write(v.watching);
        },
        .actions => |list| {
            try s.objectField("ok");
            try s.write(true);
            try s.objectField("actions");
            try s.beginArray();
            for (list) |a| {
                try s.beginObject();
                try s.objectField("name");
                try s.write(a.name);

                // Only when it is true. There are 278 of these and most
                // take nothing, so writing `false` 250 times would be a
                // quarter of the reply saying nothing.
                if (a.takes_value) {
                    try s.objectField("takes_value");
                    try s.write(true);
                }
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

fn writePlugin(s: *std.json.Stringify, v: rpc.PluginView) std.Io.Writer.Error!void {
    try s.beginObject();

    try s.objectField("key");
    try s.write(v.key);
    try s.objectField("name");
    try s.write(v.name);
    try s.objectField("kind");
    try s.write(v.kind);
    try s.objectField("enabled");
    try s.write(v.enabled);

    // Written back exactly as the manifest declared it, so an agent can
    // tell the user what it is about to switch on rather than describing
    // it from memory.
    try s.objectField("wants");
    try s.beginObject();
    try s.objectField("groups");
    try s.beginArray();
    for (v.groups) |g| try s.write(g);
    try s.endArray();
    try s.objectField("network");
    try s.write(v.network);
    try s.objectField("exec");
    try s.beginArray();
    for (v.exec) |e| try s.write(e);
    try s.endArray();
    try s.endObject();

    try s.objectField("params");
    try s.beginArray();
    for (v.params) |p| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name);
        try s.objectField("title");
        try s.write(p.title);
        try s.objectField("required");
        try s.write(p.required);
        try s.objectField("secret");
        try s.write(p.secret);

        try s.objectField("choices");
        try s.beginArray();
        for (p.choices) |c| try s.write(c);
        try s.endArray();

        // `holds` always: it is what says whether a value is there at all,
        // and it is what makes saying nothing about the value itself cost
        // nobody anything they needed.
        try s.objectField("holds");
        try s.write(p.holds);

        // `shown` only when there is something it is safe to show. An empty
        // field would invite the question of what it would have said.
        if (p.shown.len > 0) {
            try s.objectField("shown");
            try s.write(p.shown);
        }
        if (p.undeclared) {
            try s.objectField("undeclared");
            try s.write(true);
        }
        try s.endObject();
    }
    try s.endArray();

    // Left out entirely rather than sent as zero, the same rule `quiet_ms`
    // follows: absent reads as "not being measured", where `0` reads as
    // "measured, and it is zero right now". A plugin that is not running
    // has no cursor, and claiming it is at zero would say it had archived
    // nothing when it may have archived everything.
    if (v.state.len > 0) {
        try s.objectField("state");
        try s.write(v.state);
        try s.objectField("cursor");
        try s.write(v.cursor);
        try s.objectField("failures");
        try s.write(v.failures);
    }
    if (v.note.len > 0) {
        try s.objectField("note");
        try s.write(v.note);
    }

    try s.endObject();
}

fn writeTerminal(s: *std.json.Stringify, info: TerminalInfo) std.Io.Writer.Error!void {
    try s.beginObject();

    try s.objectField("id");
    try writeId(s, info.id);

    try s.objectField("role");
    try s.write(@tagName(info.role));
    try s.objectField("duty");
    try s.write(@tagName(info.duty));
    try s.objectField("held");
    try s.write(info.held);
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

test "become_supervisor takes no parameters at all" {
    // It names the caller, and the caller is not something a request gets
    // to choose. A version of this that took an id would be a terminal
    // promoting *another* terminal, which is a different and much larger
    // power than the one being added.
    var p = try parse(
        \\{"method":"become_supervisor"}
    );
    defer p.deinit();
    try testing.expectEqual(rpc.Method.become_supervisor, p.value);

    // Params that came along anyway are ignored rather than refused: the
    // shape is "no parameters", not "an empty object required".
    var extra = try parse(
        \\{"method":"become_supervisor","params":{"id":"0x2222"}}
    );
    defer extra.deinit();
    try testing.expectEqual(rpc.Method.become_supervisor, extra.value);
}

test "the work mode methods are gone from the wire" {
    // Removed rather than left parsing and failing later: a method name
    // this build no longer honours should be unknown at the door, so an
    // agent asking gets told the name is wrong instead of a puzzling
    // refusal from somewhere deeper in.
    try testing.expectError(error.UnknownMethod, parse(
        \\{"method":"set_work_mode","params":{"id":1,"mode":"infinite_directed"}}
    ));
    try testing.expectError(error.UnknownMethod, parse(
        \\{"method":"get_work_mode","params":{"id":1}}
    ));
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
        .held = false,
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
        .code = "TerminalHeld",
        .message = rpc.errorMessage(error.TerminalHeld),
    } });

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "holding this terminal") != null);
}

test "a response is one line" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const list = [_]TerminalInfo{
        .{ .id = 1, .role = .supervisor, .duty = .on, .held = false, .quiet_ms = 0, .watching = false, .rounds = 0 },
        .{ .id = 2, .role = .watched, .duty = .off, .held = true, .quiet_ms = 90_000, .watching = true, .rounds = 2 },
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

test "group_history parses its cursor and its limit" {
    var p = try parse(
        \\{"method":"group_history","params":{"group":"build","before_seq":10432,"limit":50}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("build", p.value.group_history.group);
    try testing.expectEqual(@as(u64, 10432), p.value.group_history.before_seq);
    try testing.expectEqual(@as(u64, 50), p.value.group_history.limit);
}

test "a history request may omit the cursor and the limit" {
    // Zero means "from the newest", and the ceiling on a batch is applied
    // where the batch is fetched, not here.
    var p = try parse(
        \\{"method":"group_history","params":{"group":"build"}}
    );
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0), p.value.group_history.before_seq);
    try testing.expectEqual(@as(u64, 0), p.value.group_history.limit);
}

test "a history reply carries the log cursor beside the group seq" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const lines = [_]rpc.ChatLine{.{
        .seq = 0,
        .log_seq = 10431,
        .from = 0x2222,
        .author = "worker-core",
        .at_ms = 1756000000000,
        .summary = false,
        .text = "signature is settled",
    }};
    try writeResponse(&w, .{ .messages = .{ .lines = &lines, .more = true } });

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"log_seq\":10431") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"seq\":0") != null);
}

test "a configure that only sets a parameter does not read as switching off" {
    {
        var p = try parse(
            \\{"method":"plugin_configure","params":{"key":"webhook","params":{"url":"env:U"}}}
        );
        defer p.deinit();

        // Null, not false. A request that says nothing about `enabled` must
        // not reach the guard as a request to switch the plugin off.
        try testing.expect(p.value.plugin_configure.enable == null);
        try testing.expectEqualStrings("url", p.value.plugin_configure.params[0].name);
        try testing.expectEqualStrings("env:U", p.value.plugin_configure.params[0].value);
    }

    {
        var p = try parse(
            \\{"method":"plugin_configure","params":{"key":"webhook","enabled":false}}
        );
        defer p.deinit();
        try testing.expectEqual(false, p.value.plugin_configure.enable.?);
    }

    {
        // A string where a bool was meant is a typo, and a typo switches
        // nothing either way.
        var p = try parse(
            \\{"method":"plugin_configure","params":{"key":"webhook","enabled":"true"}}
        );
        defer p.deinit();
        try testing.expect(p.value.plugin_configure.enable == null);
    }

    // A number where a value was meant is refused rather than dropped: the
    // caller meant something by it, and skipping the field would have it
    // believe a value had been set.
    try testing.expectError(error.BadParams, parse(
        \\{"method":"plugin_configure","params":{"key":"webhook","params":{"n":1}}}
    ));
}

test "a plugin listing round-trips" {
    // A few kilobytes, so on the heap: a listing carries every manifest's
    // declarations and is the one reply with no size cap of its own.
    const buf = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(buf);
    var w: std.Io.Writer = .fixed(buf);

    const archive_params = [_]rpc.PluginParamView{
        .{
            .name = "backend",
            .title = "Where to write",
            .required = true,
            .choices = &.{ "postgres", "file" },
            .holds = "literal",
            .shown = "postgres",
        },
        .{
            .name = "dsn",
            .title = "Postgres connection URI",
            .secret = true,
            .holds = "env:",
            .shown = "env:POLTER_PG",
        },
    };
    const notify_params = [_]rpc.PluginParamView{.{
        .name = "leftover",
        .holds = "literal",
        .undeclared = true,
    }};

    const list = [_]rpc.PluginView{
        .{
            .key = "chat-archive",
            .name = "Chat archive",
            .kind = "archive",
            .enabled = true,
            .groups = &.{"*"},
            .network = true,
            .exec = &.{"psql"},
            .params = &archive_params,
            .state = "feeding",
            .cursor = 1049,
            .failures = 0,
            .note = "nothing is wrong",
        },
        .{
            .key = "webhook",
            .name = "Webhook",
            .kind = "notify",
            .params = &notify_params,
        },
    };

    try writeResponse(&w, .{ .plugins = &list });
    const out = w.buffered();

    try testing.expectEqual(@as(usize, 1), count(out, "\n"));
    try testing.expect(out[out.len - 1] == '\n');

    // The running one only. An absent cursor is what stops `0` being read
    // as "it has archived nothing".
    try testing.expectEqual(@as(usize, 1), count(out, "\"state\""));
    try testing.expectEqual(@as(usize, 1), count(out, "\"cursor\""));
    try testing.expectEqual(@as(usize, 1), count(out, "\"failures\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"cursor\":1049") != null);
    try testing.expectEqual(@as(usize, 1), count(out, "\"note\""));

    // `holds` for every parameter, since it is what says a value is there
    // at all.
    try testing.expectEqual(@as(usize, 3), count(out, "\"holds\""));

    // `shown` for the two it is safe to show, and not for the undeclared
    // literal.
    try testing.expectEqual(@as(usize, 2), count(out, "\"shown\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"shown\":\"env:POLTER_PG\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"shown\":\"postgres\"") != null);

    try testing.expectEqual(@as(usize, 1), count(out, "\"undeclared\":true"));

    // What the manifest asked for, handed over unread so an agent can say
    // what it is about to switch on.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"wants\":{\"groups\":[\"*\"],\"network\":true,\"exec\":[\"psql\"]}",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"wants\":{\"groups\":[],\"network\":false,\"exec\":[]}",
    ) != null);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| : (i = at + needle.len) n += 1;
    return n;
}
