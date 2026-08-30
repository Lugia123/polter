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

/// A sequence number out of a reply, and never a negative one: these
/// count, and a negative is only ever there because the reply is
/// malformed -- which this file survives rather than asserts about.
fn u64Field(v: std.json.Value, name: []const u8) u64 {
    const n = intField(v, name) orelse return 0;
    return if (n < 0) 0 else @intCast(n);
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
    /// Where this landed in the log on disk, or 0 for a message that was
    /// never written down. Zero is the end of the road for paging back:
    /// there is nothing to join onto, and joining onto the wrong thing is
    /// worse than stopping.
    log_seq: u64 = 0,

    author: []const u8,
    at_ms: i64,
    summary: bool,
    text: []const u8,
    from_user: bool,
};

/// One task on a group's panel, copied out of a reply.
///
/// The state and the progress arrive as words and stay words. Turning them
/// into an enum here would mean this view refusing to draw a value a newer
/// host knows about, and a blank row is a worse answer than an unfamiliar
/// one.
const Task = struct {
    id: u64,
    title: []const u8,
    owner: []const u8,
    state: []const u8,
    progress: []const u8,
};

/// One member, with the id as well as the name.
///
/// The id is here for the panel: a task says who owns it as an id, and the
/// name to put beside it is only knowable through this list.
const Member = struct {
    id: []const u8,
    title: []const u8,
};

/// One group, with everything needed to draw it.
const Group = struct {
    name: []const u8,

    /// What the supervisor said this group is for. Empty when nobody has
    /// said, which is most groups most of the time.
    brief: []const u8 = "",
    messages: std.ArrayListUnmanaged(Message) = .empty,
    members: std.ArrayListUnmanaged(Member) = .empty,

    /// The panel, rebuilt from scratch on every poll.
    ///
    /// Unlike the messages, which accumulate behind a cursor, a task's
    /// state changes in place: there is no "what is new" to ask for, so
    /// the whole panel comes back each time and the old one is dropped.
    /// It is short by construction -- one line per task -- so this costs
    /// nothing worth a cursor.
    tasks: std.ArrayListUnmanaged(Task) = .empty,

    /// Highest seq seen, so each poll asks only for what is new.
    cursor: u64 = 0,

    /// How many messages at the front of `messages` were paged back out of
    /// the log rather than read forward off the socket.
    ///
    /// The trim in `refresh` is told about it, because trimming to a fixed
    /// `keep_messages` would throw these away on the next poll -- half a
    /// second after the reader pulled them in.
    history_count: usize = 0,

    /// Set when the host said there is nothing older. Stops the view asking
    /// again on every frame somebody spends sitting at the top.
    history_done: bool = false,
};

const Chat = struct {
    alloc: Allocator,
    io: std.Io,
    host: *Host,

    /// Names and member lists, rebuilt on each refresh.
    arena: std.heap.ArenaAllocator,

    /// Messages, which outlive a refresh.
    ///
    /// Separate from `arena` because the conversation accumulates: each
    /// poll asks only for what is new, so anything already shown has to
    /// still be here. Resetting this with the rest is what left the view
    /// frozen on the first screenful once replies started being capped --
    /// every poll asked from zero and got the same oldest batch back.
    store: std.heap.ArenaAllocator,

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

    groups: std.ArrayListUnmanaged(Group) = .empty,
    current: usize = 0,

    /// Which of the right-hand column's two tabs is showing.
    ///
    /// **On the right only.** The group list on the left does not move,
    /// because a task belongs to a group: switching tab must not change
    /// which group you are looking at.
    view: View = .chat,

    /// Where each tab's label was drawn last frame, for hit testing.
    /// Rebuilt every frame because the labels shrink on a narrow window.
    tab_row: u16 = 0,

    /// Where the right-hand column starts, so a click's column can be put
    /// into the same frame of reference the tab spans were recorded in.
    /// The spans are relative to that column, not to the screen.
    tabs_left: u16 = 0,
    tab_spans: [2]struct { from: u16 = 0, to: u16 = 0 } = .{ .{}, .{} },

    /// How far the message pane is scrolled back, **in rendered rows**.
    ///
    /// Rows, not messages: one report from an agent can be forty rows, and
    /// scrolling by message stepped over a screenful at a time.
    scroll: usize = 0,

    /// Whether the top of the conversation was on screen last frame.
    ///
    /// Recorded while drawing and acted on in the loop: how far back you
    /// *can* scroll depends on the width the text was just wrapped to, and
    /// drawing is not the place to talk to a socket.
    at_top: bool = false,

    /// Where each group's name was drawn last frame, so a click can be
    /// turned back into a group. Rebuilt every frame because the list
    /// moves when a group is made or destroyed.
    group_rows: std.ArrayListUnmanaged(usize) = .empty,

    /// The bounds of the group pane last frame, for hit testing.
    groups_top: u16 = 0,
    groups_left: u16 = 0,
    groups_right: u16 = 0,

    should_quit: bool = false,

    /// Where a complaint from the host is kept while it is on screen.
    ///
    /// A buffer rather than an allocation, because `err` is otherwise
    /// always a static `@errorName`, and one owned string among several
    /// borrowed ones is a lifetime nobody would get right twice.
    err_buf: [200]u8 = undefined,

    /// How many more polls a complaint stays up for.
    ///
    /// Without it a refusal lived for less than the half second until the
    /// next successful poll, which cleared it -- the person pressed a key,
    /// something flickered, and the group was still there with no reason
    /// given. Refusals are the one kind of message here that has to be
    /// readable at human speed.
    err_hold: usize = 0,

    /// The group the confirmation box is asking about, or null when no box
    /// is showing.
    ///
    /// The **name**, not the index. The list reorders itself under this
    /// window -- a group going quiet moves it down -- and an index taken
    /// when the box opened could be pointing at a different group by the
    /// time somebody presses `y`.
    confirm: ?Confirm = null,

    /// Shown in place of the input line when something went wrong. Cleared
    /// by the next successful poll, so a transient failure does not leave a
    /// stale complaint on screen.
    err: ?[]const u8 = null,

    const View = enum { chat, tasks };

    /// A group name held while the box is up.
    ///
    /// Inline rather than allocated: `Chat.isValidName` holds a group name
    /// to 48 bytes, and a fixed buffer cannot be left dangling by the
    /// refresh that rebuilds every string in the window half a second later.
    const Confirm = struct {
        buf: [48]u8 = undefined,
        len: usize = 0,

        fn name(self: *const Confirm) []const u8 {
            return self.buf[0..self.len];
        }
    };

    const Verdict = enum { forget, cancel };

    /// What one key means while the confirmation box is up.
    ///
    /// A function of the key and nothing else, so that it can be tested
    /// without a terminal attached -- and this is the part worth testing:
    /// everything that is not an explicit yes has to come back `cancel`,
    /// because the failure mode is a group leaving the list that the
    /// person never agreed to remove. Defaulting the other way, or
    /// leaving a key unhandled so it falls through to the ordinary
    /// bindings, are the two ways that goes wrong.
    fn verdictOf(key: vaxis.Key) Verdict {
        if (key.matches('y', .{}) or
            key.matches('y', .{ .shift = true }) or
            key.matches(vaxis.Key.enter, .{}))
        {
            return .forget;
        }
        return .cancel;
    }

    const Event = union(enum) {
        key_press: vaxis.Key,
        mouse: vaxis.Mouse,
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
            .store = .init(alloc),
            .frame = .init(alloc),
            .tty = try .init(io, tty_buf),
            .vx = undefined,
            .env = env,
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
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.env.deinit();
        self.groups.deinit(self.alloc);
        self.group_rows.deinit(self.alloc);
        self.frame.deinit();
        self.arena.deinit();
        self.store.deinit();
    }

    fn run(self: *Chat) !void {
        var loop: vaxis.Loop(Event) = .init(self.io, &self.tty, &self.vx);
        try loop.start();
        defer loop.stop();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        try self.vx.setTitle(writer, "Polter — terminal conversations");
        try self.vx.queryTerminal(writer, .fromSeconds(1));

        // Without this the pane is a picture: no clicking a group, no
        // wheel. It was never switched on, which is most of why this felt
        // like something to read rather than something to use.
        try self.vx.setMouseMode(writer, true);

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

            // After the events, because scrolling to the top is an event,
            // and before the draw, because a frame has to be redrawable and
            // a socket call is not.
            if (self.at_top) self.fetchHistory() catch |err| {
                self.err = @errorName(err);
            };

            try self.draw();
            try self.vx.render(writer);
            try writer.flush();

            // Sleeping rather than blocking on an event, because the poll
            // has to happen whether or not anybody touches the keyboard.
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }
    }

    /// How much of a conversation the view keeps in hand.
    ///
    /// Scrolling further back than this is what paging through the log is
    /// for; holding everything for a session that runs for days is not.
    const keep_messages = 500;

    /// The most a group holds once the log has been paged into it. The
    /// point of a ceiling at all is that a window left open for days should
    /// not become a way to load the whole log into memory.
    const max_held = 5000;

    /// How many older messages to ask for at a time.
    const history_batch = 100;

    /// How many polls a complaint stays on screen -- about six seconds at
    /// `poll_ms`, which is long enough to read a sentence.
    const err_polls = 12;

    /// Ask the host what is new.
    ///
    /// **Only what is new.** The first version rebuilt everything from
    /// `since: 0` on every poll, which was harmless while a reply carried
    /// the whole conversation -- and became a frozen screen the moment
    /// replies were capped, because every poll asked from the beginning
    /// and got the same oldest batch back. The `cursor` this advances was
    /// there from the start and had never been used.
    fn refresh(self: *Chat) !void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const store = self.store.allocator();

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

        // Carried over by name: the id of a group is its name, and what
        // has to survive is the cursor and everything already read.
        var kept: std.ArrayListUnmanaged(Group) = .empty;
        defer kept.deinit(self.alloc);
        try kept.appendSlice(self.alloc, self.groups.items);
        self.groups.clearRetainingCapacity();

        for (names.items, 0..) |name, gi| {
            var group: Group = for (kept.items) |old| {
                if (std.mem.eql(u8, old.name, name)) break old;
            } else .{ .name = try store.dupe(u8, name) };

            group.brief = briefs.items[gi];

            group.members.clearRetainingCapacity();
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
                    try group.members.append(store, .{
                        .id = try store.dupe(u8, stringField(item, "id") orelse ""),
                        .title = try store.dupe(u8, title),
                    });
                }
            }

            // The panel, whole. Tolerated rather than required: a host
            // that does not know the tool leaves the tab empty, which is
            // the honest picture, not a reason to take the window down.
            group.tasks.clearRetainingCapacity();
            {
                var buf: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(
                    &buf,
                    "{{\"method\":\"task_list\",\"params\":{{\"group\":\"{s}\"}}}}",
                    .{name},
                );
                const v = self.host.callJson(arena, line) catch std.json.Value.null;
                for (arrayField(v, "tasks") catch &.{}) |item| {
                    try group.tasks.append(store, .{
                        .id = u64Field(item, "task"),
                        .title = try store.dupe(u8, stringField(item, "title") orelse ""),
                        .owner = try store.dupe(u8, stringField(item, "owner") orelse ""),
                        .state = try store.dupe(u8, stringField(item, "state") orelse ""),
                        .progress = try store.dupe(u8, stringField(item, "progress") orelse ""),
                    });
                }
            }

            // Asked repeatedly while the host says there is more, so a
            // backlog is caught up in one refresh rather than one capped
            // batch per poll interval.
            var rounds: usize = 0;
            while (rounds < 32) : (rounds += 1) {
                var buf: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(
                    &buf,
                    "{{\"method\":\"group_read\",\"params\":{{\"group\":\"{s}\",\"since\":{d}}}}}",
                    .{ name, group.cursor },
                );
                const v = try self.host.callJson(arena, line);

                var read: usize = 0;
                for (arrayField(v, "messages") catch &.{}) |item| {
                    const from = stringField(item, "from") orelse "";
                    const seq = u64Field(item, "seq");

                    try group.messages.append(store, .{
                        .log_seq = u64Field(item, "log_seq"),
                        .author = try store.dupe(u8, stringField(item, "author") orelse "?"),
                        .at_ms = intField(item, "at_ms") orelse 0,
                        .summary = boolField(item, "summary") orelse false,
                        .text = try store.dupe(u8, stringField(item, "text") orelse ""),

                        // The user is id 0; `Surface.id` is never zero.
                        .from_user = std.mem.eql(u8, from, "0x0000000000000000"),
                    });

                    if (seq > group.cursor) group.cursor = seq;
                    read += 1;
                }

                if (read == 0) break;
                if (!(boolField(v, "more") orelse false)) break;
            }

            // Oldest first, because the newest is what has to stay -- with
            // room for what was paged back in on top of what is live.
            // Cutting to `keep_messages` regardless is the bug this shape
            // exists to avoid: the reader scrolls up, the next poll throws
            // away what they just pulled, and the view drops back down on
            // its own. Whatever comes off the front comes off the history
            // first, so the count follows it down.
            const trim = planTrim(group.messages.items.len, group.history_count);
            if (trim.drop > 0) {
                const keep = group.messages.items.len - trim.drop;
                std.mem.copyForwards(
                    Message,
                    group.messages.items[0..keep],
                    group.messages.items[trim.drop..],
                );
                group.messages.shrinkRetainingCapacity(keep);
                group.history_count = trim.history;
            }

            try self.groups.append(self.alloc, group);
        }

        if (self.current >= self.groups.items.len) self.current = 0;

        if (self.err_hold > 0) {
            self.err_hold -= 1;
        } else {
            self.err = null;
        }
    }

    /// What a poll has to throw away, and what that leaves of the history.
    const Trim = struct { drop: usize, history: usize };

    fn planTrim(len: usize, history: usize) Trim {
        const limit = @min(keep_messages + history, max_held);
        if (len <= limit) return .{ .drop = 0, .history = history };
        const drop = len - limit;
        return .{ .drop = drop, .history = history - @min(history, drop) };
    }

    /// Where the next batch of history joins on, given what a group holds.
    const Seam = union(enum) {
        /// Unused, kept so the union still says that "nothing to fetch
        /// yet" is a state this could be in. Holding nothing used to mean
        /// this; see `seamOf` for why it no longer can.
        wait,

        /// The oldest message never reached the disk -- the log is off, or
        /// it predates the log keeping a seq. Nothing joins on here.
        stop,

        /// Ask for what came before this.
        before: u64,
    };

    /// **Holding nothing means asking for the newest, not waiting.**
    ///
    /// This used to answer `wait`, on the reasoning that an empty group
    /// gets a seam as soon as its first message arrives. That is true
    /// within one run of Polter and false across a restart, which is the
    /// case that matters: the group comes back with its name and its note
    /// and no messages (`Chat.restoreShell`), while the log on disk still
    /// holds every word of it. The seam could only ever come from a live
    /// message, so until somebody posted, the whole history was
    /// unreachable -- the user opened last night's group and read a blank
    /// screen with the record sitting on disk beside it.
    ///
    /// Zero is not a sentinel invented here: `before_seq == 0` is already
    /// "no lower bound, newest first" in `ChatLog.history`. A group that
    /// genuinely has nothing behind it gets an empty batch back and
    /// `history_done`, which is the same answer `wait` gave, one call
    /// later.
    fn seamOf(msgs: []const Message) Seam {
        if (msgs.len == 0) return .{ .before = 0 };
        const seq = msgs[0].log_seq;
        return if (seq == 0) .stop else .{ .before = seq };
    }

    /// Pull one batch of older messages out of the log on disk.
    ///
    /// One batch per pass, however long somebody holds page-up: the point
    /// is to stay ahead of the eye, not to reach the beginning of the log
    /// in one go.
    ///
    /// `log_seq` is the seam, not `seq`: the group's own count restarts at
    /// 1 every time Polter does, so paging by it reads the wrong run.
    fn fetchHistory(self: *Chat) !void {
        if (self.groups.items.len == 0) return;
        const group = &self.groups.items[self.current];
        if (group.history_done) return;

        // The ceiling is not something to fetch into and then throw away.
        // Without this the trim in `refresh` discards each batch about as
        // fast as it lands and the next pass asks for the same hundred
        // again -- a socket call, and a backwards walk of the log on disk,
        // every frame for as long as somebody rests at the top. Left
        // unset, `history_done` lets this resume if the group is ever
        // trimmed back below the ceiling: there *is* older, we just have
        // nowhere to put it.
        if (group.messages.items.len >= max_held) return;

        const before = switch (seamOf(group.messages.items)) {
            .wait => return,
            .stop => {
                group.history_done = true;
                return;
            },
            .before => |v| v,
        };

        // Its own arena: `self.arena` holds the briefs and is reset by the
        // next poll, and `store` is where anything kept has to end up.
        var scratch: std.heap.ArenaAllocator = .init(self.alloc);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const store = self.store.allocator();

        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"method\":\"group_history\",\"params\":{{\"group\":\"{s}\",\"before_seq\":{d},\"limit\":{d}}}}}",
            .{ group.name, before, history_batch },
        );
        const v = try self.host.callJson(temp, line);

        var batch: std.ArrayListUnmanaged(Message) = .empty;
        for (arrayField(v, "messages") catch &.{}) |item| {
            const from = stringField(item, "from") orelse "";
            try batch.append(temp, .{
                .log_seq = u64Field(item, "log_seq"),
                .author = try store.dupe(u8, stringField(item, "author") orelse "?"),

                // Already wall clock, the same as `group_read` hands over.
                .at_ms = intField(item, "at_ms") orelse 0,
                .summary = boolField(item, "summary") orelse false,
                .text = try store.dupe(u8, stringField(item, "text") orelse ""),

                // The user is id 0; `Surface.id` is never zero.
                .from_user = std.mem.eql(u8, from, "0x0000000000000000"),
            });
        }

        // Oldest first on the wire, so the batch goes in as one run and
        // keeps the order it arrived in. `scroll` counts rows up from the
        // bottom, so adding above the reader leaves them looking at exactly
        // what they were looking at -- nothing here touches it. Nor
        // `cursor`: that one counts forward through what is live, and these
        // carry no number in its scale.
        try group.messages.insertSlice(store, 0, batch.items);
        group.history_count += batch.items.len;

        // A short batch is not the end -- the host caps by bytes as well as
        // by count and says so in `more`. An empty one is, whatever `more`
        // claims, or the loop asks forever for nothing.
        if (batch.items.len == 0) group.history_done = true;
        if (!(boolField(v, "more") orelse false)) group.history_done = true;
    }

    fn update(self: *Chat, event: Event) !void {
        switch (event) {
            .winsize => |ws| try self.vx.resize(self.alloc, self.tty.writer(), ws),

            .mouse => |m| self.onMouse(m),

            .key_press => |key| {
                // The box takes every key while it is up, including `q`.
                // A confirmation somebody can walk away from by pressing
                // something else is not a confirmation, and quitting out
                // from under one would leave them unsure what they just
                // did.
                if (self.confirm) |c| {
                    switch (verdictOf(key)) {
                        .forget => self.forgetGroup(c.name()),
                        .cancel => {},
                    }
                    self.confirm = null;
                    return;
                }

                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches('q', .{ .ctrl = true }) or
                    key.matches('q', .{}))
                {
                    self.should_quit = true;
                    return;
                }

                // Take the selected group off the list.
                //
                // **A bare key, like `q` and `t`, and not a chord.** A
                // modifier was asked for first and does not work here, for
                // three reasons that are worth keeping written down so the
                // question is not reopened:
                //
                //   * Cmd+Backspace, the obvious one on macOS, is already
                //     bound: `src/config/Config.zig` ships it as
                //     `text:\x15`, delete-to-start-of-line, which is
                //     standard line editing everywhere. Taking it would
                //     break a key people use without thinking.
                //   * This view does not turn the Kitty keyboard protocol
                //     on, and the legacy encodings have no bit for Cmd or
                //     Super at all. The chord would simply never arrive.
                //   * Turning that protocol on means sending `CSI > 1 u`
                //     and restoring it on the way out -- and a view that
                //     is killed rather than quit never gets to restore it,
                //     leaving the terminal in a keyboard mode the person
                //     did not choose. That is a real cost to carry for one
                //     key.
                //
                // And the thing a chord would guard against is what the
                // box below already guards against. Two answers to one
                // question is one too many.
                if (key.matches('d', .{})) {
                    self.askForget();
                    return;
                }

                // Left and right move between the right-hand column's
                // two tabs, the way up and down move through the groups.
                // `t` as well, because the arrows are a reach when one
                // hand is on the mouse.
                if (key.matches(vaxis.Key.right, .{}) or
                    key.matches(vaxis.Key.left, .{}) or
                    key.matches('t', .{}))
                {
                    self.selectView(if (self.view == .chat) .tasks else .chat);
                    return;
                }

                if (key.matches(vaxis.Key.tab, .{})) {
                    self.selectGroup(self.current +| 1);
                    return;
                }
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    self.selectGroup(self.current -| 1);
                    return;
                }

                // Up and down move through the groups, which is what the
                // arrows mean everywhere else in a two-pane list.
                if (key.matches(vaxis.Key.down, .{})) {
                    self.selectGroup(self.current +| 1);
                    return;
                }
                if (key.matches(vaxis.Key.up, .{})) {
                    self.selectGroup(self.current -| 1);
                    return;
                }

                if (key.matches(vaxis.Key.page_up, .{})) {
                    self.scroll +|= 10;
                    return;
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    self.scroll -|= 10;
                    return;
                }
                if (key.matches(vaxis.Key.home, .{})) {
                    self.scroll = std.math.maxInt(usize);
                    return;
                }
                if (key.matches(vaxis.Key.end, .{})) {
                    self.scroll = 0;
                    return;
                }
            },
        }
    }

    /// Put the confirmation box up for whichever group is selected.
    fn askForget(self: *Chat) void {
        if (self.groups.items.len == 0) return;

        var c: Confirm = .{};

        const name = self.groups.items[self.current].name;
        if (name.len == 0 or name.len > c.buf.len) return;

        @memcpy(c.buf[0..name.len], name);
        c.len = name.len;
        self.confirm = c;
    }

    /// Take a group off the list.
    ///
    /// **The list, not the record.** The host leaves every day file under
    /// `<state>/chat/<group>/` exactly where it was; all that happens is
    /// that the group stops being offered here. The box says so in as many
    /// words, because "delete" is the word people read as "last night's
    /// conversation is gone".
    ///
    /// A refusal is shown rather than swallowed. Rearranging groups is the
    /// supervisor's, and this view runs with whatever standing the terminal
    /// it was started in has -- so in a terminal that is not a supervisor
    /// the host says no, and the person has to be told that rather than
    /// left watching a key do nothing.
    fn forgetGroup(self: *Chat, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "{{\"method\":\"group_destroy\",\"params\":{{\"group\":\"{s}\"}}}}",
            .{name},
        ) catch return;

        // Its own arena, not the one `refresh` uses: that one holds the
        // strings the group list is currently drawn from, and resetting it
        // here would leave the next frame reading freed bytes.
        var scratch: std.heap.ArenaAllocator = .init(self.alloc);
        defer scratch.deinit();

        const v = self.host.callJson(scratch.allocator(), line) catch |err| {
            self.err = @errorName(err);
            return;
        };

        if (boolField(v, "ok") orelse true) {
            // Gone from the list, so whatever was selected is no longer
            // where it was. The next poll rebuilds the list; until then,
            // stepping back keeps the selection inside it.
            self.selectGroup(self.current -| 1);
            self.err = null;
            return;
        }

        // Copied into a buffer of our own: the reply is about to be freed
        // with the scratch arena, and the complaint has to outlive it.
        const message = stringField(v, "message") orelse "the host refused";
        const kept = @min(message.len, self.err_buf.len);
        @memcpy(self.err_buf[0..kept], message[0..kept]);
        self.err = self.err_buf[0..kept];
        self.err_hold = err_polls;
    }

    /// Switch the right-hand column between the conversation and the panel.
    ///
    /// The scroll goes back to the bottom, for the same reason changing
    /// group does: it counts rows in whatever was last laid out, and the
    /// two views have nothing like the same number of them.
    fn selectView(self: *Chat, view: View) void {
        if (self.view == view) return;
        self.view = view;
        self.scroll = 0;

        // And what was on screen was the conversation's top. Left set, the
        // next pass spends a read on the log for a view that is not even
        // showing.
        self.at_top = false;
    }

    /// Move to a group by index, clamped, and start it at the newest.
    fn selectGroup(self: *Chat, index: usize) void {
        if (self.groups.items.len == 0) return;
        const last = self.groups.items.len - 1;
        self.current = @min(index, last);

        // A group you have just opened should show what was said last, not
        // wherever you happened to be reading in the previous one.
        self.scroll = 0;

        // And what was on screen was the *other* group's top. Carried over,
        // it spends a read on the log for a group the reader has not
        // scrolled back in at all.
        self.at_top = false;
    }

    fn onMouse(self: *Chat, m: vaxis.Mouse) void {
        switch (m.button) {
            // The wheel scrolls whatever is under it, and the message pane
            // is the only thing long enough to scroll.
            .wheel_up => self.scroll +|= 3,
            .wheel_down => self.scroll -|= 3,

            .left => {
                if (m.type != .press) return;
                if (m.col < 0 or m.row < 0) return;

                // Mouse coordinates are signed and the panes are not, so
                // the comparison happens in one type rather than at three
                // different call sites.
                const col: u16 = @intCast(m.col);
                const row: u16 = @intCast(m.row);

                // The tabs first: they sit in the right-hand column, which
                // starts where the group pane ends, so testing them after
                // the group test would never be reached.
                if (row == self.tab_row) {
                    const x = col -| self.tabs_left;
                    for (self.tab_spans, 0..) |span, i| {
                        if (span.to == span.from) continue;
                        if (x >= span.from and x < span.to) {
                            self.selectView(if (i == 0) .chat else .tasks);
                            return;
                        }
                    }
                }

                if (col < self.groups_left or col >= self.groups_right) return;
                if (row < self.groups_top) return;

                const offset: usize = row - self.groups_top;
                for (self.group_rows.items, 0..) |at, i| {
                    if (at == offset) {
                        self.selectGroup(i);
                        return;
                    }
                }
            },

            else => {},
        }
    }

    // The palette, in one place so the whole thing can be re-tuned without
    // hunting for colour literals. Indexed rather than RGB: these follow
    // whatever theme the terminal is wearing, and a chat window that
    // ignores the user's theme looks like it came from somewhere else.
    const c_frame: vaxis.Color = .{ .index = 8 };
    const c_title: vaxis.Color = .{ .index = 4 };
    const c_selected_bg: vaxis.Color = .{ .index = 4 };
    const c_selected_fg: vaxis.Color = .{ .index = 0 };
    const c_author: vaxis.Color = .{ .index = 6 };
    const c_user: vaxis.Color = .{ .index = 5 };
    const c_dim: vaxis.Color = .{ .index = 8 };
    const c_alarm: vaxis.Color = .{ .index = 1 };

    fn draw(self: *Chat) !void {
        // Cleared here so every path that ends without laying the messages
        // out -- no room, no groups, a pane too narrow -- leaves it false
        // rather than leaving last frame's answer standing.
        self.at_top = false;

        const win = self.vx.window();

        // A window with no room in it is not a window to draw into. This
        // happens before the first resize arrives and whenever somebody
        // drags a split down to nothing.
        if (win.width == 0 or win.height == 0) return;

        // Last frame's strings have been rendered and are no longer read.
        _ = self.frame.reset(.retain_capacity);
        win.clear();

        // Narrow windows drop the side column rather than squeezing it:
        // eighteen columns of group names beside twelve of message is two
        // unreadable panes instead of one readable one.
        const side_width: u16 = if (win.width >= 60) 24 else 0;

        if (side_width > 0) {
            const groups_height = @min(
                @max(win.height / 3, 6),
                win.height -| 4,
            );

            self.drawGroups(win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = side_width,
                .height = groups_height,
            }));

            self.drawMembers(win.child(.{
                .x_off = 0,
                .y_off = groups_height,
                .width = side_width,
                .height = win.height -| groups_height,
            }));

            // The rule between the columns, drawn once rather than as two
            // borders meeting: two adjacent lines read as a gutter.
            var row: u16 = 0;
            while (row < win.height) : (row += 1) {
                win.writeCell(side_width -| 1, row, .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = .{ .fg = c_frame },
                });
            }
        }

        self.tabs_left = side_width;

        const right = win.child(.{
            .x_off = side_width,
            .y_off = 0,
            .width = win.width -| side_width,
            .height = win.height,
        });

        try self.drawConversation(right);

        // Over everything, and last, because that is what both of these
        // are: a complaint and a question that the rest of the window is
        // the background to.
        self.drawError(win);
        self.drawConfirm(win);
    }

    /// The one-line complaint along the bottom.
    ///
    /// It had a field and no drawing at all: every failure this view could
    /// have reported was written into `err` and then never shown. A key
    /// that is refused has to say so.
    fn drawError(self: *Chat, win: vaxis.Window) void {
        const text = self.err orelse return;
        if (win.height == 0 or win.width < 8 or text.len == 0) return;

        const row = win.height -| 1;
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            win.writeCell(col, row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = c_alarm, .fg = c_selected_fg },
            });
        }

        const line = std.fmt.allocPrint(
            self.frame.allocator(),
            " {s}",
            .{text},
        ) catch text;

        _ = win.printSegment(.{
            .text = line,
            .style = .{ .bg = c_alarm, .fg = c_selected_fg, .bold = true },
        }, .{ .row_offset = row, .col_offset = 0 });
    }

    /// The box that asks before a group leaves the list.
    ///
    /// **Drawn here rather than raised as a system dialog.** This view is a
    /// terminal window on purpose (see `docs/poltergeist/chatui.md`); a box
    /// from the operating system would arrive in front of whatever the
    /// person was doing in another app, for a question about a list in this
    /// one.
    ///
    /// The wording is the load-bearing part. "Delete" reads as "last
    /// night's conversation is gone", and it is not: the records stay
    /// exactly where they are and stay greppable, and only the listing
    /// changes. The box has to say that before somebody presses `y`, not
    /// afterwards.
    fn drawConfirm(self: *Chat, win: vaxis.Window) void {
        const c = self.confirm orelse return;
        if (win.height < 7 or win.width < 30) return;

        const alloc = self.frame.allocator();

        const title = std.fmt.allocPrint(
            alloc,
            "把群「{s}」从列表里移除？",
            .{c.name()},
        ) catch "把这个群从列表里移除？";

        const lines = [_][]const u8{
            title,
            "",
            "聊天记录一个字都不会删：磁盘上",
            "<state>/chat/ 里的每一天原样保留，",
            "以后还能翻、还能 grep。",
            "移除的只是这个列表里的一行。",
            "",
            "y 确认    其他任意键取消",
        };

        var inner_w: u16 = 0;
        for (lines) |l| inner_w = @max(inner_w, measure(l));

        const width = @min(win.width, inner_w + 4);
        const height = @min(win.height, @as(u16, lines.len) + 2);

        const box = win.child(.{
            .x_off = (win.width -| width) / 2,
            .y_off = (win.height -| height) / 2,
            .width = width,
            .height = height,
            .border = .{ .where = .all, .style = .{ .fg = c_alarm } },
        });

        // Painted rather than left transparent: it sits on top of the
        // conversation, and text showing through a question is a question
        // that is hard to read.
        var row: u16 = 0;
        while (row < box.height) : (row += 1) {
            var col: u16 = 0;
            while (col < box.width) : (col += 1) {
                box.writeCell(col, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{},
                });
            }
        }

        for (lines, 0..) |l, i| {
            const y: u16 = @intCast(i);
            if (y >= box.height) break;
            _ = box.printSegment(.{
                .text = l,
                .style = if (i == 0)
                    .{ .bold = true }
                else if (i == lines.len - 1)
                    .{ .fg = c_title, .bold = true }
                else
                    .{ .fg = c_dim },
            }, .{ .row_offset = y, .col_offset = 1 });
        }
    }

    /// The list of groups, and where each one was drawn.
    fn drawGroups(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 4) return;

        self.groups_top = 1;
        self.groups_left = 0;
        self.groups_right = win.width -| 1;
        self.group_rows.clearRetainingCapacity();

        // The key is named here because it is otherwise unfindable: this
        // view has no menu and no help line, so a key nobody is told about
        // is a key that does not exist.
        self.heading(win, "群聊 / GROUPS  d 移除");

        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = "  (还没有群)",
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 1, .col_offset = 0 });
            return;
        }

        var row: u16 = 1;
        for (self.groups.items, 0..) |group, i| {
            if (row >= win.height) break;
            self.group_rows.append(self.alloc, row) catch {};

            const selected = i == self.current;
            const style: vaxis.Style = if (selected) .{
                .bg = c_selected_bg,
                .fg = c_selected_fg,
                .bold = true,
            } else .{};

            // The selected row is painted across the whole pane, so it
            // reads as a row rather than as a differently coloured word.
            if (selected) {
                var col: u16 = 0;
                while (col < win.width -| 1) : (col += 1) {
                    win.writeCell(col, row, .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = style,
                    });
                }
            }

            const label = std.fmt.allocPrint(
                self.frame.allocator(),
                "{s} {s}",
                .{ if (selected) "▸" else " ", group.name },
            ) catch group.name;

            _ = win.printSegment(
                .{ .text = label, .style = style },
                .{ .row_offset = row, .col_offset = 0 },
            );

            row += 1;
        }
    }

    fn drawMembers(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 4) return;

        self.heading(win, "成员 / MEMBERS");
        if (self.groups.items.len == 0) return;

        const group = self.groups.items[self.current];
        var row: u16 = 1;
        for (group.members.items) |m| {
            if (row >= win.height) break;

            _ = win.printSegment(.{
                .text = "●",
                .style = .{ .fg = c_author },
            }, .{ .row_offset = row, .col_offset = 0 });

            _ = win.printSegment(
                .{ .text = m.title },
                .{ .row_offset = row, .col_offset = 2 },
            );
            row += 1;
        }
    }

    /// A section title with a rule under it.
    fn heading(self: *Chat, win: vaxis.Window, text: []const u8) void {
        _ = self;
        _ = win.printSegment(.{
            .text = text,
            .style = .{ .fg = c_title, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 0 });
    }

    /// The right-hand column: which group, what it is for, and what was
    /// said in it.
    fn drawConversation(self: *Chat, win: vaxis.Window) !void {
        if (win.height == 0 or win.width < 8) return;

        self.drawTabs(win);

        const name = if (self.groups.items.len > 0)
            self.groups.items[self.current].name
        else
            "";

        _ = win.printSegment(.{
            .text = name,
            .style = .{ .fg = c_title, .bold = true },
        }, .{ .row_offset = 1, .col_offset = 1 });

        // The brief is what this group is *for*, so it sits with the name
        // rather than in the scroll where it would leave the screen. It
        // stays put across both tabs: it says what the group is about, and
        // that is as true of the work as of the talk.
        var head_height: u16 = 2;
        const brief = self.currentBrief();
        if (brief.len > 0 and win.height > 4) {
            var rows: std.ArrayListUnmanaged([]const u8) = .empty;
            defer rows.deinit(self.alloc);

            const inner = win.width -| 2;
            try layout.wrap(self.alloc, &rows, brief, inner, measure);

            // Two lines of it at most: a brief long enough to fill the
            // screen is one the supervisor should have trimmed, and this
            // is not the place to read it in full.
            for (rows.items[0..@min(rows.items.len, 2)], 0..) |line, i| {
                _ = win.printSegment(.{
                    .text = line,
                    .style = .{ .fg = c_dim, .italic = true },
                }, .{ .row_offset = @intCast(2 + i), .col_offset = 1 });
                head_height += 1;
            }
        }

        // The rule under the header.
        if (win.height > head_height) {
            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                win.writeCell(col, head_height, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = .{ .fg = c_frame },
                });
            }
        }

        const body_top = head_height + 1;
        if (win.height <= body_top) return;

        const body = win.child(.{
            .x_off = 0,
            .y_off = body_top,
            .width = win.width,
            .height = win.height -| body_top,
        });

        switch (self.view) {
            .chat => try self.drawMessages(body),
            .tasks => self.drawTasks(body),
        }
    }

    /// The two tabs across the top of the right-hand column.
    ///
    /// Drawn every frame and their positions recorded, because how wide
    /// the labels are depends on how wide the window is: a narrow window
    /// gets the short forms, the same way it loses the side column
    /// entirely rather than squeezing it.
    fn drawTabs(self: *Chat, win: vaxis.Window) void {
        self.tab_row = 0;
        self.tab_spans = .{ .{}, .{} };

        const labels = tabLabels(win.width);

        var col: u16 = 1;
        for (labels, 0..) |label, i| {
            const width = measure(label);
            if (col + width >= win.width) break;

            const on = (i == 0) == (self.view == .chat);
            _ = win.printSegment(.{
                .text = label,
                .style = if (on) .{
                    .bg = c_selected_bg,
                    .fg = c_selected_fg,
                    .bold = true,
                } else .{ .fg = c_dim },
            }, .{ .row_offset = 0, .col_offset = col });

            self.tab_spans[i] = .{ .from = col, .to = col + width };
            col += width + 1;
        }
    }

    /// The panel: one row per task, oldest first.
    ///
    /// **Everything in the group, closed and cancelled included.** This is
    /// the person at the keyboard's view, and looking back over last night
    /// is most of what they want it for. A worker asking the same question
    /// through `task_list` is handed only its own open work; the two are
    /// different questions with different answers, and this is the one
    /// that shows the whole night.
    fn drawTasks(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 8) return;

        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = "  没有群聊。总管建群之后，任务会出现在这里。",
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const group = self.groups.items[self.current];
        if (group.tasks.items.len == 0) {
            _ = win.printSegment(.{
                .text = "  这个群还没有任务。",
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const alloc = self.frame.allocator();

        // Clamped here rather than where the key is handled, the same as
        // the messages: how far you can scroll depends on what was drawn.
        const max_scroll = group.tasks.items.len -| win.height;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const first = group.tasks.items.len -| win.height -| self.scroll;
        const last = @min(group.tasks.items.len, first + win.height);

        for (group.tasks.items[first..last], 0..) |task, i| {
            const y: u16 = @intCast(i);
            const shut = std.mem.eql(u8, task.state, "closed") or
                std.mem.eql(u8, task.state, "cancelled");

            _ = win.printSegment(.{
                .text = stateMark(task.state),
                .style = .{ .fg = if (shut) c_dim else c_author, .bold = true },
            }, .{ .row_offset = y, .col_offset = 1 });

            // Progress before the title, so the column of words lines up
            // and "blocked" can be found by running an eye down it -- that
            // is the one a supervisor is looking for.
            const line = std.fmt.allocPrint(alloc, "{s: <8}  {s}  {s}", .{
                if (shut) task.state else task.progress,
                task.title,
                self.ownerName(task.owner),
            }) catch task.title;

            _ = win.printSegment(.{
                .text = line,
                .style = if (shut) .{ .fg = c_dim } else .{},
            }, .{ .row_offset = y, .col_offset = 3 });
        }

        if (self.scroll > 0) {
            const note = std.fmt.allocPrint(alloc, "↓ {d}", .{self.scroll}) catch "↓";
            const at = win.width -| @as(u16, @intCast(note.len)) -| 1;
            _ = win.printSegment(.{
                .text = note,
                .style = .{ .fg = c_selected_bg, .bold = true },
            }, .{ .row_offset = win.height -| 1, .col_offset = at });
        }
    }

    /// What the two tabs are called at this width.
    ///
    /// Short forms on a narrow window rather than truncated long ones,
    /// which is the precedent the side column already sets: it is dropped
    /// entirely below sixty columns rather than squeezed into something
    /// unreadable.
    fn tabLabels(width: u16) [2][]const u8 {
        return if (width >= 34)
            .{ " 群聊 / CHAT ", " 任务 / TASKS " }
        else
            .{ " 群聊 ", " 任务 " };
    }

    /// One glyph for where a task stands, and the progress word with it.
    ///
    /// Words rather than a lookup that could fail: a value this build does
    /// not recognise draws as itself, which is readable, instead of as a
    /// blank, which is not.
    fn stateMark(state: []const u8) []const u8 {
        if (std.mem.eql(u8, state, "closed")) return "✓";
        if (std.mem.eql(u8, state, "cancelled")) return "✗";
        return "○";
    }

    /// What to call the terminal a task belongs to.
    ///
    /// The panel says who owns a task as an id; the members list is the
    /// only place that id has a name. A terminal that has since closed is
    /// no longer a member, so its id is shown as itself rather than
    /// silently blanked -- an unowned task and one whose owner has gone
    /// are different things and the person has to be able to tell.
    fn ownerName(self: *const Chat, owner: []const u8) []const u8 {
        if (owner.len == 0) return "";
        if (std.mem.eql(u8, owner, "0x0000000000000000")) return "· 未分配";

        for (self.groups.items[self.current].members.items) |m| {
            if (std.mem.eql(u8, m.id, owner)) return m.title;
        }
        return owner;
    }

    fn currentBrief(self: *const Chat) []const u8 {
        if (self.groups.items.len == 0) return "";
        return self.groups.items[self.current].brief;
    }

    /// The messages, laid out as rows and then drawn top-down.
    ///
    /// Laid out first, drawn second. The version this replaces printed
    /// bottom-up straight into the pane, which meant a line longer than
    /// the pane wrapped onto rows that had already been drawn -- putting
    /// fragments of three messages on one line. Rows have to be counted
    /// before anything is placed.
    fn drawMessages(self: *Chat, win: vaxis.Window) !void {
        if (win.height == 0 or win.width < 8) return;
        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = "  没有群聊。总管建群之后，对话会出现在这里。",
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const group = self.groups.items[self.current];
        const alloc = self.frame.allocator();

        // Two columns of margin, and the body indented under its header so
        // the eye can find where one message stops.
        const body_width = win.width -| 4;
        if (body_width == 0) return;

        var rows: std.ArrayListUnmanaged(layout.Row) = .empty;
        defer rows.deinit(alloc);

        // Said once, at the top of what there is, so that reaching the
        // beginning is something the reader sees rather than infers from
        // scrolling that has stopped doing anything. Appended while `rows`
        // is still empty, which is what inserting at the front means here.
        if (group.history_done) {
            try rows.append(alloc, .{
                .text = "── 没有更早的了 ──",
                .kind = .notice,
                .message = 0,
            });
        }

        for (group.messages.items, 0..) |m, mi| {
            const stamp = formatTime(alloc, m.at_ms);
            const header = std.fmt.allocPrint(alloc, "{s}  {s}{s}", .{
                stamp,
                m.author,
                if (m.summary) "  (摘要)" else "",
            }) catch m.author;

            try rows.append(alloc, .{
                .text = header,
                .kind = .header,
                .message = mi,
            });

            var lines = std.mem.splitScalar(u8, m.text, '\n');
            while (lines.next()) |line| {
                var wrapped: std.ArrayListUnmanaged([]const u8) = .empty;
                defer wrapped.deinit(alloc);
                try layout.wrap(alloc, &wrapped, line, body_width, measure);

                for (wrapped.items) |piece| {
                    try rows.append(alloc, .{
                        .text = piece,
                        .kind = .body,
                        .message = mi,
                    });
                }
            }

            try rows.append(alloc, .{ .text = "", .kind = .gap, .message = mi });
        }

        // Scrolling is clamped here rather than where the key is handled,
        // because how far back you *can* go depends on the width the text
        // was just wrapped to.
        const visible = win.height;
        const max_scroll = rows.items.len -| visible;
        if (self.scroll > max_scroll) self.scroll = max_scroll;

        const first = rows.items.len -| visible -| self.scroll;
        self.at_top = first == 0;
        const last = @min(rows.items.len, first + visible);

        for (rows.items[first..last], 0..) |row, i| {
            const y: u16 = @intCast(i);
            switch (row.kind) {
                .gap => {},

                .header => {
                    const from_user = group.messages.items[row.message].from_user;
                    _ = win.printSegment(.{
                        .text = row.text,
                        .style = .{
                            .fg = if (from_user) c_user else c_author,
                            .bold = true,
                        },
                    }, .{ .row_offset = y, .col_offset = 1 });
                },

                .body => {
                    _ = win.printSegment(
                        .{ .text = row.text },
                        .{ .row_offset = y, .col_offset = 3 },
                    );
                },

                // Deliberately outside the `.header` arm's lookup into
                // `group.messages`: this row belongs to no message, and on
                // a group with none that index would be out of bounds.
                .notice => {
                    _ = win.printSegment(.{
                        .text = row.text,
                        .style = .{ .fg = c_dim, .italic = true },
                    }, .{ .row_offset = y, .col_offset = 1 });
                },
            }
        }

        // A marker when there is more below, so scrolled-back is a state
        // you can see rather than one you infer from nothing arriving.
        if (self.scroll > 0 and win.height > 0) {
            const note = std.fmt.allocPrint(alloc, "↓ {d}", .{self.scroll}) catch "↓";
            const at = win.width -| @as(u16, @intCast(note.len)) -| 1;
            _ = win.printSegment(.{
                .text = note,
                .style = .{ .fg = c_selected_bg, .bold = true },
            }, .{ .row_offset = win.height -| 1, .col_offset = at });
        }
    }

    /// What a string will occupy on this terminal, in columns.
    fn measure(text: []const u8) u16 {
        return vaxis.gwidth.gwidth(text, .unicode);
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

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    _ = layout;
}

test "a poll leaves the live messages capped where it always did" {
    const t = Chat.planTrim(600, 0);
    try testing.expectEqual(@as(usize, 100), t.drop);
    try testing.expectEqual(@as(usize, 0), t.history);
}

test "a poll does not eat what the reader just paged in" {
    // The whole point of `history_count`: four hundred pulled back out of
    // the log sit above the live five hundred and survive the next poll.
    const t = Chat.planTrim(900, 400);
    try testing.expectEqual(@as(usize, 0), t.drop);
    try testing.expectEqual(@as(usize, 400), t.history);

    try testing.expectEqual(@as(usize, 0), Chat.planTrim(600, 200).drop);
}

test "a new message pushes the oldest history out, and the count follows" {
    const t = Chat.planTrim(901, 400);
    try testing.expectEqual(@as(usize, 1), t.drop);
    try testing.expectEqual(@as(usize, 399), t.history);
}

test "the hard ceiling wins over the history" {
    const t = Chat.planTrim(6000, 5000);
    try testing.expectEqual(@as(usize, 1000), t.drop);
    try testing.expectEqual(@as(usize, 4000), t.history);
}

test "trimming more than there is history leaves none of it" {
    const t = Chat.planTrim(6000, 100);
    try testing.expectEqual(@as(usize, 5400), t.drop);
    try testing.expectEqual(@as(usize, 0), t.history);
}

/// A message with nothing in it but the seam, which is all `seamOf` reads.
fn seamFixture(log_seq: u64) Message {
    return .{
        .log_seq = log_seq,
        .author = "",
        .at_ms = 0,
        .summary = false,
        .text = "",
        .from_user = false,
    };
}

test "a group holding nothing asks for the newest, not for nothing" {
    // **This test used to assert `wait`, and that was the bug.**
    //
    // Waiting for a live message to establish the seam is right within one
    // run and wrong across a restart, which is the case that matters: the
    // group comes back with no messages in memory and its whole log still
    // on disk, so the seam never arrives and the history is unreachable.
    // The user opened last night's group and read a blank screen.
    //
    // Zero already means "no lower bound, newest first" to
    // `ChatLog.history`, so this asks for the newest batch rather than
    // inventing a state.
    const seam = Chat.seamOf(&.{});
    try testing.expect(std.meta.activeTag(seam) == .before);
    try testing.expectEqual(@as(u64, 0), seam.before);
}

test "a message that never reached the disk ends the walk" {
    const msgs = [_]Message{seamFixture(0)};
    try testing.expect(std.meta.activeTag(Chat.seamOf(&msgs)) == .stop);
}

test "the next batch joins onto the oldest message held" {
    const msgs = [_]Message{ seamFixture(41), seamFixture(42) };
    const seam = Chat.seamOf(&msgs);
    try testing.expect(std.meta.activeTag(seam) == .before);
    try testing.expectEqual(@as(u64, 41), seam.before);
}

test "the tabs shrink rather than being cut in half" {
    // The side column's precedent: a narrow window drops what it cannot
    // draw properly instead of squeezing it.
    const wide = Chat.tabLabels(80);
    try testing.expect(std.mem.indexOf(u8, wide[0], "CHAT") != null);
    try testing.expect(std.mem.indexOf(u8, wide[1], "TASKS") != null);

    const narrow = Chat.tabLabels(30);
    try testing.expect(std.mem.indexOf(u8, narrow[0], "CHAT") == null);
    try testing.expect(std.mem.indexOf(u8, narrow[0], "群聊") != null);
    try testing.expect(std.mem.indexOf(u8, narrow[1], "任务") != null);
}

test "the confirmation box takes yes for an answer and nothing else for one" {
    // Yes is yes, in the two ways somebody types it and by pressing
    // return on the box.
    try testing.expectEqual(Chat.Verdict.forget, Chat.verdictOf(.{ .codepoint = 'y' }));
    try testing.expectEqual(Chat.Verdict.forget, Chat.verdictOf(.{
        .codepoint = 'y',
        .mods = .{ .shift = true },
    }));
    try testing.expectEqual(
        Chat.Verdict.forget,
        Chat.verdictOf(.{ .codepoint = vaxis.Key.enter }),
    );

    // And everything else is no -- including the keys that do something
    // else in this window, which is the case that matters: `d` opened the
    // box, and pressing it again must not be the answer to it. `q` would
    // otherwise quit out from under an unanswered question.
    for ([_]u21{
        'n',
        'N',
        'd',
        'q',
        't',
        ' ',
        vaxis.Key.escape,
        vaxis.Key.up,
        vaxis.Key.down,
        vaxis.Key.tab,
    }) |cp| {
        try testing.expectEqual(Chat.Verdict.cancel, Chat.verdictOf(.{ .codepoint = cp }));
    }

    // A `y` that arrives with a modifier on it is not the plain `y` the
    // box asked for either.
    try testing.expectEqual(Chat.Verdict.cancel, Chat.verdictOf(.{
        .codepoint = 'y',
        .mods = .{ .ctrl = true },
    }));
}

test "a task's mark says which of the three states it is in" {
    try testing.expectEqualStrings("○", Chat.stateMark("open"));
    try testing.expectEqualStrings("✓", Chat.stateMark("closed"));
    try testing.expectEqualStrings("✗", Chat.stateMark("cancelled"));

    // A word this build does not know is drawn as open rather than as a
    // blank: an unfamiliar row beats an invisible one.
    try testing.expectEqualStrings("○", Chat.stateMark("something-newer"));
}
