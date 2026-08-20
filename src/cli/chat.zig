//! The window onto what the terminals have said to each other.
//!
//! A TUI rather than a native window, and so one program instead of one per
//! platform. It also inherits everything a terminal already does well:
//! equal-width text so pasted code lines up, ANSI so a pasted log keeps its
//! colours, and CJK display and input handled by the host surface rather
//! than by us. See `docs/poltergeist/chatui.md`.
//!
//! It reads and writes over the same unix socket the agents use. What makes
//! it the *user* rather than the terminal it happens to run in is that the
//! host opened this surface for the chat and remembers doing so; see
//! `App.isChatSurface`. Nothing here declares an identity, because anything
//! that could would work just as well for an agent.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const vaxis = @import("vaxis");
const layout = @import("chat_layout.zig");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

const log = std.log.scoped(.chat);

/// Longest line the host will read or write.
// Matches the sidecar (`cli/mcp.zig`). A reply larger than this is
// `StreamTooLong` and a connection that never recovers, so the server caps
// what it sends (`rpc.read_budget_bytes`) and this is the headroom for the
// JSON escaping on top of it.
const max_line = 256 * 1024;

/// How often to ask the host what is new.
///
/// Polled rather than pushed: this is a window somebody has open while
/// doing something else, and a push channel would be a lot of machinery
/// for a view that can simply ask again. Half a second is below what reads
/// as lag and far above what the host notices.
const poll_ms = 500;

pub const Options = struct {
    /// Socket to reach Polter on. Defaults to `GHOSTTY_POLTER_SOCKET`.
    socket: ?[]const u8 = null,

    /// Token identifying this terminal. Defaults to `GHOSTTY_POLTER_TOKEN`.
    token: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `chat` command shows the groups the terminals are talking in, and
/// lets the person at the keyboard join in.
///
/// It finds Polter through `GHOSTTY_POLTER_SOCKET` and
/// `GHOSTTY_POLTER_TOKEN`, both of which are in every terminal's
/// environment, so normally it takes no arguments at all.
///
/// Requires `poltergeist-mcp` to be enabled, since that is what opens the
/// socket.
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
        return complain(io, "GHOSTTY_POLTER_SOCKET");

    const token = opts.token orelse
        env.get("GHOSTTY_POLTER_TOKEN") orelse
        return complain(io, "GHOSTTY_POLTER_TOKEN");

    var host: Host = try .connect(alloc, io, socket_path, token);
    defer host.deinit();

    var tty_buf: [4096]u8 = undefined;
    const chat = try Chat.create(alloc, io, &host, &tty_buf);
    defer chat.destroy();

    try chat.run();
    return 0;
}

/// Say why this will not start, where the person who ran it will see it.
///
/// To stderr, not the log. This runs in a terminal the user just opened
/// from a menu, and on macOS the log goes to `os_log` -- so a `log.err`
/// here is a terminal that closes after a tenth of a second having said
/// nothing at all, which is exactly how this was first reported.
fn complain(io: std.Io, missing: []const u8) u8 {
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.File = .stderr();
    var writer = stderr.writer(io, &buffer);

    writer.interface.print(
        \\Polter: no {s} in this terminal, so there is nothing to talk to.
        \\
        \\The conversations view runs inside Polter and needs the agent
        \\socket, which is off by default. Put this in
        \\$XDG_CONFIG_HOME/polter/config.polter and restart Polter:
        \\
        \\    poltergeist-mcp = true
        \\
    , .{missing}) catch return 1;
    writer.end() catch {};

    return 1;
}

/// The connection back to Polter.
///
/// Same shape as the sidecar's: one line out, one line back. Kept separate
/// rather than shared because the two want different things from a reply --
/// the sidecar forwards it verbatim, this one parses it.
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

        try self.writer.interface.print(
            \\{{"method":"auth","params":{{"token":"{s}"}}}}
        ++ "\n", .{token});
        try self.writer.interface.flush();

        const reply = (try self.reader.interface.takeDelimiter('\n')) orelse
            return error.EndOfStream;
        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
            log.err("polter refused this token", .{});
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

    /// One request, one reply. The reply borrows the read buffer and is
    /// only valid until the next call, so callers copy what they keep.
    fn call(self: *Host, line: []const u8) ![]const u8 {
        try self.writer.interface.writeAll(line);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();

        // `takeDelimiter` consumes the newline; the exclusive form leaves
        // it and every later call comes back empty forever.
        return (try self.reader.interface.takeDelimiter('\n')) orelse
            error.EndOfStream;
    }

    /// A request whose reply is parsed. The returned value owns nothing:
    /// it borrows the arena passed in.
    fn callJson(
        self: *Host,
        arena: Allocator,
        line: []const u8,
    ) !std.json.Value {
        const reply = try self.call(line);
        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            reply,
            .{},
        );
        return parsed;
    }
};

/// Reading a reply.
///
/// Every one of these tolerates the wrong shape rather than asserting it.
/// The reply comes over a socket from another process, and a malformed one
/// should leave the window looking wrong for a moment -- not take it down.
fn arrayField(v: std.json.Value, name: []const u8) ![]const std.json.Value {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadReply,
    };
    const field = obj.get(name) orelse return error.BadReply;
    return switch (field) {
        .array => |a| a.items,
        else => error.BadReply,
    };
}

fn stringOf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |str| str,
        else => null,
    };
}

fn stringField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return stringOf(obj.get(name) orelse return null);
}

fn intField(v: std.json.Value, name: []const u8) ?i64 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

fn boolField(v: std.json.Value, name: []const u8) ?bool {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// One message, copied out of a reply so it outlives the read buffer.
const Message = struct {
    author: []const u8,
    at_ms: i64,
    summary: bool,
    text: []const u8,
    from_user: bool,
};

/// One group, with everything needed to draw it.
const Group = struct {
    name: []const u8,

    /// What the supervisor said this group is for. Empty when nobody has
    /// said, which is most groups most of the time.
    brief: []const u8 = "",
    messages: std.ArrayListUnmanaged(Message) = .empty,
    members: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Highest seq seen, so each poll asks only for what is new.
    cursor: u64 = 0,
};

const Chat = struct {
    alloc: Allocator,
    io: std.Io,
    host: *Host,

    /// The messages and member names being shown. Reset on each refresh.
    arena: std.heap.ArenaAllocator,

    /// Strings made while drawing one frame, and nothing else.
    ///
    /// A separate arena because these have to outlive the draw call: vaxis
    /// stores a *slice* in each cell rather than copying the text, so
    /// anything handed to `printSegment` must still be there when `render`
    /// runs. Written into a stack buffer, as this was at first, the counts
    /// and timestamps came out as garbage bytes on screen.
    frame: std.heap.ArenaAllocator,

    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    env: std.process.Environ.Map,
    text_input: vaxis.widgets.TextInput,

    groups: std.ArrayListUnmanaged(Group) = .empty,
    current: usize = 0,

    /// How far the message pane is scrolled back from the newest message.
    scroll: usize = 0,

    should_quit: bool = false,

    /// Shown in place of the input line when something went wrong. Cleared
    /// by the next successful poll, so a transient failure does not leave a
    /// stale complaint on screen.
    err: ?[]const u8 = null,

    const Event = union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    };

    /// Built on the heap and never moved after.
    ///
    /// `Tty` and `Vaxis` both hand out pointers into themselves -- the
    /// event loop is given `&self.tty` and `&self.vx` -- so a copy leaves
    /// those pointing at a frame that is about to go away. Returning this
    /// by value looked fine, compiled fine, and panicked before it drew
    /// anything.
    fn create(alloc: Allocator, io: std.Io, host: *Host, tty_buf: []u8) !*Chat {
        const self = try alloc.create(Chat);
        errdefer alloc.destroy(self);

        var env = try global.environMap();
        errdefer env.deinit();

        self.* = .{
            .alloc = alloc,
            .io = io,
            .host = host,
            .arena = .init(alloc),
            .frame = .init(alloc),
            .tty = try .init(io, tty_buf),
            .vx = undefined,
            .env = env,
            .text_input = .init(alloc),
        };
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(io, alloc, &self.env, .{});
        return self;
    }

    fn destroy(self: *Chat) void {
        const alloc = self.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    fn deinit(self: *Chat) void {
        self.text_input.deinit();
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.env.deinit();
        self.groups.deinit(self.alloc);
        self.frame.deinit();
        self.arena.deinit();
    }

    fn run(self: *Chat) !void {
        var loop: vaxis.Loop(Event) = .init(self.io, &self.tty, &self.vx);
        try loop.start();
        defer loop.stop();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        try self.vx.setTitle(writer, "Polter — terminal conversations");
        try self.vx.queryTerminal(writer, .fromSeconds(1));

        // Wait for the first event before drawing anything. Until the
        // terminal has told us its size, the window is zero by zero, and
        // drawing into that is not merely empty -- it walks off the end of
        // a zero-length buffer. The first run of this panicked there.
        try loop.pollEvent();

        var last_poll: std.Io.Timestamp = .now(self.io, .awake);
        try self.refresh();

        while (!self.should_quit) {
            // Events first, so typing stays responsive regardless of what
            // the poll interval is doing.
            while (try loop.tryEvent()) |event| try self.update(event);

            const now: std.Io.Timestamp = .now(self.io, .awake);
            if (last_poll.durationTo(now).toMilliseconds() >= poll_ms) {
                last_poll = now;
                self.refresh() catch |err| {
                    self.err = @errorName(err);
                };
            }

            try self.draw();
            try self.vx.render(writer);
            try writer.flush();

            // Sleeping rather than blocking on an event, because the poll
            // has to happen whether or not anybody touches the keyboard.
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }
    }

    /// Ask the host what is new.
    ///
    /// The whole state is rebuilt from the reply rather than patched,
    /// because a half-updated view is worse than one that is a moment
    /// behind, and the amount of data here is small.
    fn refresh(self: *Chat) !void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var briefs: std.ArrayListUnmanaged([]const u8) = .empty;
        {
            const v = try self.host.callJson(arena, "{\"method\":\"group_list\"}");
            for (try arrayField(v, "groups")) |item| {
                const name = stringField(item, "name") orelse continue;
                try names.append(arena, name);
                try briefs.append(arena, stringField(item, "brief") orelse "");
            }
        }

        self.groups.clearRetainingCapacity();
        for (names.items, 0..) |name, gi| {
            var group: Group = .{ .name = name, .brief = briefs.items[gi] };

            {
                var buf: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(
                    &buf,
                    "{{\"method\":\"group_members\",\"params\":{{\"group\":\"{s}\"}}}}",
                    .{name},
                );
                const v = try self.host.callJson(arena, line);
                for (arrayField(v, "members") catch &.{}) |item| {
                    const title = stringField(item, "title") orelse continue;
                    try group.members.append(arena, title);
                }
            }

            {
                var buf: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(
                    &buf,
                    "{{\"method\":\"group_read\",\"params\":{{\"group\":\"{s}\",\"since\":0}}}}",
                    .{name},
                );
                const v = try self.host.callJson(arena, line);
                for (arrayField(v, "messages") catch &.{}) |item| {
                    const from = stringField(item, "from") orelse "";
                    try group.messages.append(arena, .{
                        .author = stringField(item, "author") orelse "?",
                        .at_ms = intField(item, "at_ms") orelse 0,
                        .summary = boolField(item, "summary") orelse false,
                        .text = stringField(item, "text") orelse "",

                        // The user is id 0; `Surface.id` is never zero.
                        .from_user = std.mem.eql(u8, from, "0x0000000000000000"),
                    });
                }
            }

            try self.groups.append(self.alloc, group);
        }

        if (self.current >= self.groups.items.len) self.current = 0;
        self.err = null;
    }

    fn send(self: *Chat) !void {
        if (self.groups.items.len == 0) return;

        const text = try self.text_input.toOwnedSlice();
        defer self.alloc.free(text);

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        const group = self.groups.items[self.current].name;

        var buf: [max_line]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(
            "{{\"method\":\"group_post\",\"params\":{{\"group\":\"{s}\",\"text\":",
            .{group},
        ) catch return error.TooLong;
        var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
        s.write(trimmed) catch return error.TooLong;
        w.writeAll("}}") catch return error.TooLong;

        const reply = try self.host.call(w.buffered());
        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
            self.err = "could not send";
            return;
        }

        self.scroll = 0;
        try self.refresh();
    }

    fn update(self: *Chat, event: Event) !void {
        switch (event) {
            .winsize => |ws| try self.vx.resize(self.alloc, self.tty.writer(), ws),

            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches('q', .{ .ctrl = true }))
                {
                    self.should_quit = true;
                    return;
                }

                if (key.matches(vaxis.Key.tab, .{})) {
                    if (self.groups.items.len > 0) {
                        self.current = (self.current + 1) % self.groups.items.len;
                        self.scroll = 0;
                    }
                    return;
                }

                if (key.matches(vaxis.Key.enter, .{})) {
                    self.send() catch |err| {
                        self.err = @errorName(err);
                    };
                    return;
                }

                if (key.matches(vaxis.Key.page_up, .{})) {
                    self.scroll +|= 5;
                    return;
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    self.scroll -|= 5;
                    return;
                }

                try self.text_input.update(.{ .key_press = key });
            },
        }
    }

    fn draw(self: *Chat) !void {
        const win = self.vx.window();

        // A window with no room in it is not a window to draw into. This
        // happens before the first resize arrives and whenever somebody
        // drags a split down to nothing.
        if (win.width == 0 or win.height == 0) return;

        // Last frame's strings have been rendered and are no longer read.
        _ = self.frame.reset(.retain_capacity);

        win.clear();

        const tabs_height: u16 = 1;
        const members_width: u16 = 22;
        const input_height: u16 = 2;

        try self.drawTabs(win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = tabs_height,
        }));

        const body_height = win.height -| tabs_height;

        self.drawMembers(win.child(.{
            .x_off = 0,
            .y_off = tabs_height,
            .width = members_width,
            .height = body_height,
        }));

        const right_width = win.width -| members_width;
        // The brief sits above the messages: it is the answer to "what is
        // this group" and belongs where the eye lands first.
        const brief_height: u16 = if (self.currentBrief().len > 0) 2 else 0;
        if (brief_height > 0) self.drawBrief(win.child(.{
            .x_off = members_width,
            .y_off = tabs_height,
            .width = right_width,
            .height = brief_height,
        }));

        try self.drawMessages(win.child(.{
            .x_off = members_width,
            .y_off = tabs_height + brief_height,
            .width = right_width,
            .height = body_height -| input_height -| brief_height,
        }));

        self.drawInput(win.child(.{
            .x_off = members_width,
            .y_off = win.height -| input_height,
            .width = right_width,
            .height = input_height,
        }));
    }

    fn drawTabs(self: *Chat, win: vaxis.Window) !void {
        if (win.height == 0 or win.width == 0) return;
        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = " no groups yet — the supervisor makes them ",
                .style = .{ .dim = true },
            }, .{});
            return;
        }

        var col: u16 = 1;
        for (self.groups.items, 0..) |group, i| {
            const selected = i == self.current;
            const res = win.printSegment(.{
                .text = group.name,
                .style = .{
                    .bold = selected,
                    .reverse = selected,
                    .dim = !selected,
                },
            }, .{ .col_offset = col });
            col = res.col + 2;
            if (col >= win.width) break;
        }
    }

    fn drawMembers(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width == 0) return;
        if (self.groups.items.len == 0) return;
        const group = self.groups.items[self.current];

        const header = std.fmt.allocPrint(
            self.frame.allocator(),
            "{d} here",
            .{group.members.items.len},
        ) catch "members";
        _ = win.printSegment(.{
            .text = header,
            .style = .{ .dim = true },
        }, .{ .col_offset = 1 });

        for (group.members.items, 0..) |title, i| {
            const row: u16 = @intCast(i + 2);
            if (row >= win.height) break;

            _ = win.printSegment(.{
                .text = "• ",
                .style = .{ .dim = true },
            }, .{ .row_offset = row, .col_offset = 1 });

            _ = win.printSegment(.{ .text = title }, .{
                .row_offset = row,
                .col_offset = 3,
            });
        }
    }

    fn drawMessages(self: *Chat, win: vaxis.Window) !void {
        if (win.height == 0 or win.width == 0) return;
        if (self.groups.items.len == 0) return;
        const group = self.groups.items[self.current];

        // Drawn from the bottom up, because the newest message is the one
        // that must always be on screen.
        var row: i32 = @as(i32, @intCast(win.height)) - 1;
        var i: usize = group.messages.items.len;
        var skipped: usize = 0;

        while (i > 0 and row >= 0) {
            i -= 1;
            const m = group.messages.items[i];

            if (skipped < self.scroll) {
                skipped += 1;
                continue;
            }

            // Body first: it is below the author line, and we are going up.
            var lines = std.mem.splitScalar(u8, m.text, '\n');
            var body: std.ArrayListUnmanaged([]const u8) = .empty;
            defer body.deinit(self.alloc);
            while (lines.next()) |l| try body.append(self.alloc, l);

            var b = body.items.len;
            while (b > 0 and row >= 0) {
                b -= 1;
                _ = win.printSegment(.{ .text = body.items[b] }, .{
                    .row_offset = @intCast(row),
                    .col_offset = 2,
                });
                row -= 1;
            }

            if (row < 0) break;

            _ = win.printSegment(.{
                .text = m.author,
                .style = .{
                    .bold = true,
                    .fg = if (m.from_user) .{ .index = 4 } else .default,
                },
            }, .{ .row_offset = @intCast(row), .col_offset = 1 });

            const stamp = formatTime(self.frame.allocator(), m.at_ms);
            if (win.width > stamp.len + 2) {
                _ = win.printSegment(.{
                    .text = stamp,
                    .style = .{ .dim = true },
                }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(win.width - stamp.len - 1),
                });
            }

            if (m.summary) {
                _ = win.printSegment(.{
                    .text = " (summary)",
                    .style = .{ .dim = true, .italic = true },
                }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(@min(
                        win.width -| 1,
                        m.author.len + 1,
                    )),
                });
            }

            row -= 2;
        }
    }

    fn currentBrief(self: *const Chat) []const u8 {
        if (self.groups.items.len == 0) return "";
        return self.groups.items[self.current].brief;
    }

    fn drawBrief(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 4) return;

        _ = win.printSegment(.{
            .text = self.currentBrief(),
            .style = .{ .italic = true, .dim = true },
        }, .{ .col_offset = 1 });
    }

    fn drawInput(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 4) return;
        if (self.err) |e| {
            _ = win.printSegment(.{
                .text = e,
                .style = .{ .fg = .{ .index = 1 } },
            }, .{ .col_offset = 1 });
            return;
        }

        _ = win.printSegment(.{
            .text = "> ",
            .style = .{ .dim = true },
        }, .{ .col_offset = 1 });

        self.text_input.draw(win.child(.{
            .x_off = 3,
            .y_off = 0,
            .width = win.width -| 3,
            .height = 1,
        }));
    }
};

/// `struct tm`, declared here because the standard library has no binding
/// for it and no timezone handling of its own.
///
/// Declared in full even though only two fields are read: `localtime_r`
/// writes into whatever it is given, so a struct that is short by a field
/// is a buffer overrun. The first nine are POSIX; the last two are a BSD
/// extension that both macOS and glibc have.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

/// `HH:MM` in the reader's own timezone.
///
/// Local rather than UTC because the person reading this is sitting in
/// front of it, and a time eight hours off is worse than no time at all --
/// it looks right and means something else. Via libc rather than by hand
/// so that daylight saving is somebody else's problem.
///
/// Allocated rather than written into a caller's buffer, because what comes
/// back has to outlive this call: vaxis keeps the slice, not a copy.
fn formatTime(alloc: Allocator, at_ms: i64) []const u8 {
    if (at_ms <= 0) return "";

    const secs: i64 = @divTrunc(at_ms, std.time.ms_per_s);
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return "";

    return std.fmt.allocPrint(
        alloc,
        "{d:0>2}:{d:0>2}",
        .{ @as(u32, @intCast(@mod(tm.hour, 24))), @as(u32, @intCast(@mod(tm.min, 60))) },
    ) catch "";
}

test {
    _ = layout;
}
