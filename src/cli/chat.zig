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
const chat_stats = @import("chat_stats.zig");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");

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
    /// The `0x…` id of whoever said it.
    ///
    /// Kept because the statistics count by id: a terminal that has closed
    /// is gone from the members list but is still on every message it sent,
    /// and counting by name loses it the moment its tab goes away.
    from: []const u8 = "",

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
/// Blanks to pad a column with, long enough for any task number a group
/// will ever hold.
const spaces = " " ** 20;

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

    /// The panel's history for the group being looked at, and the name of
    /// the group it belongs to.
    ///
    /// **One group's, not every group's.** The statistics are about the
    /// group in front of you, and reading every group's record on every
    /// poll would spend the whole night's disk on tabs nobody has open.
    /// Held in its own arena because it is thrown away and read again
    /// rather than accumulated: `store` never shrinks, and a window left
    /// open for days would grow a copy of the record every few seconds.
    events_arena: std.heap.ArenaAllocator,
    events: std.ArrayListUnmanaged(chat_stats.Event) = .empty,
    events_group: []const u8 = "",

    /// Polls left before the record is read again. Zero reads on the next
    /// pass; see `fetchEvents` for why this is not every poll.
    events_wait: usize = 0,

    /// Which of the right-hand column's tabs is showing.
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
    tab_spans: [3]struct { from: u16 = 0, to: u16 = 0 } = .{ .{}, .{}, .{} },

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

    const View = enum {
        chat,
        tasks,
        stats,

        /// The next tab round, so left and right wrap rather than stop.
        /// Written over the enum rather than as two `if`s at the key
        /// handler, because a tab added later is then a change in one
        /// place and not three.
        fn next(self: View) View {
            const all = std.enums.values(View);
            const i = @intFromEnum(self);
            return all[(i + 1) % all.len];
        }

        fn prev(self: View) View {
            const all = std.enums.values(View);
            const i = @intFromEnum(self);
            return all[(i + all.len - 1) % all.len];
        }
    };

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
            .events_arena = .init(alloc),
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
        self.events_arena.deinit();
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
            // **Also while the statistics are showing, and not only when
            // somebody has scrolled to the top.** The numbers are over
            // whatever this window happens to hold, and what it holds by
            // default is what arrived since it opened -- so a group with a
            // night behind it reported "23 messages" and dated its first
            // line to whenever the window was opened. Both were wrong in
            // the direction that looks right. One batch per pass until the
            // log says there is no more.
            if (self.at_top or self.view == .stats) self.fetchHistory() catch |err| {
                self.err = @errorName(err);
            };

            // Only while the tab is showing: the numbers are read to be
            // looked at, and reading them for a tab nobody has open is a
            // walk over the record every ten seconds for nothing.
            if (self.view == .stats) self.fetchEvents() catch |err| {
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
                        .from = try store.dupe(u8, from),
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
                .from = try store.dupe(u8, from),
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

    /// How many polls between rereads of the panel's record.
    ///
    /// Twenty polls is ten seconds. Not every poll, because unlike the
    /// conversation this is not a cursor asking for what is new -- there
    /// is no "since" for the record, so a reread is the whole thing again,
    /// and the whole thing is a few hundred lines off disk. Ten seconds is
    /// far below how fast anybody reads a page of numbers and far above
    /// what the host notices.
    const events_every = 20;

    /// How many events one page asks for, and how many pages one reread
    /// walks back through. The product is the ceiling on what the
    /// statistics are computed over: past it the oldest end is simply not
    /// counted, which understates rather than invents.
    const events_batch = 200;
    const events_pages = 8;

    /// Read the panel's own history for the group being looked at.
    ///
    /// Tolerated rather than required, the same way `task_list` is: a host
    /// that does not know the tool leaves the tab saying it has nothing to
    /// count, which is the honest picture and not a reason to take the
    /// window down.
    fn fetchEvents(self: *Chat) !void {
        if (self.groups.items.len == 0) return;
        const name = self.groups.items[self.current].name;

        // A different group is read at once, however recently the last one
        // was: what is on screen has changed, and counting down would leave
        // the previous group's numbers under the new group's name.
        if (std.mem.eql(u8, self.events_group, name) and self.events_wait > 0) {
            self.events_wait -= 1;
            return;
        }

        _ = self.events_arena.reset(.retain_capacity);
        const arena = self.events_arena.allocator();
        self.events = .empty;
        self.events_group = try arena.dupe(u8, name);
        self.events_wait = events_every;

        var scratch: std.heap.ArenaAllocator = .init(self.alloc);
        defer scratch.deinit();
        const temp = scratch.allocator();

        // Backwards, a page at a time, the way the record is paged. Each
        // page arrives oldest first, so each goes in front of the one
        // before it and the whole list ends up in the order things
        // happened.
        var before: u64 = 0;
        var page: usize = 0;
        while (page < events_pages) : (page += 1) {
            var buf: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &buf,
                "{{\"method\":\"task_history\",\"params\":{{\"group\":\"{s}\",\"before_seq\":{d},\"limit\":{d}}}}}",
                .{ name, before, events_batch },
            );
            const v = self.host.callJson(temp, line) catch return;

            var batch: std.ArrayListUnmanaged(chat_stats.Event) = .empty;
            for (arrayField(v, "events") catch &.{}) |item| {
                try batch.append(temp, .{
                    .seq = u64Field(item, "seq"),
                    .at_ms = intField(item, "at_ms") orelse 0,
                    .op = try arena.dupe(u8, stringField(item, "op") orelse ""),
                    .task = u64Field(item, "task"),
                    .title = try arena.dupe(u8, stringField(item, "title") orelse ""),
                    .owner = try arena.dupe(u8, stringField(item, "owner") orelse ""),
                    .state = try arena.dupe(u8, stringField(item, "state") orelse ""),
                    .progress = try arena.dupe(u8, stringField(item, "progress") orelse ""),
                });
            }

            if (batch.items.len == 0) break;
            try self.events.insertSlice(arena, 0, batch.items);

            // The oldest of this page is where the next one joins on. A
            // short page is not the end -- the host caps by bytes as well
            // as by count and says which in `more`.
            before = batch.items[0].seq;
            if (!(boolField(v, "more") orelse false)) break;
        }
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
                // tabs, the way up and down move through the groups.
                // `t` as well, because the arrows are a reach when one
                // hand is on the mouse.
                if (key.matches(vaxis.Key.right, .{}) or
                    key.matches('t', .{}))
                {
                    self.selectView(self.view.next());
                    return;
                }
                if (key.matches(vaxis.Key.left, .{})) {
                    self.selectView(self.view.prev());
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

        // Opening the tab is the one moment somebody is definitely waiting
        // for the numbers, so the next pass reads rather than counting
        // down. Everything else about the schedule is in `fetchEvents`.
        if (view == .stats) self.events_wait = 0;

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
                            self.selectView(@enumFromInt(i));
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

        const title = fill(alloc, tr("Take the group \"{0}\" off this list?"), &.{c.name()});

        const lines = [_][]const u8{
            title,
            "",
            tr("Not one word of the conversation is deleted:"),
            tr("every day of it stays exactly as it is under"),
            tr("<state>/chat/, to be read and grepped later."),
            tr("What goes is one row of this list."),
            "",
            tr("y to confirm    any other key cancels"),
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
        self.heading(win, tr("GROUPS   d removes"));

        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = tr("  (no groups yet)"),
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

        self.heading(win, tr("MEMBERS"));
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
            .stats => self.drawStats(body),
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
        self.tab_spans = .{ .{}, .{}, .{} };

        const labels = tabLabels(self.frame.allocator());

        var col: u16 = 1;
        for (labels, 0..) |label, i| {
            const width = measure(label);
            if (col + width >= win.width) break;

            const on = i == @intFromEnum(self.view);
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
                .text = tr("No groups. Tasks will appear here once a supervisor makes one."),
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const group = self.groups.items[self.current];
        if (group.tasks.items.len == 0) {
            _ = win.printSegment(.{
                .text = tr("No tasks in this group yet."),
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const alloc = self.frame.allocator();

        // How wide the number column has to be for this group.
        //
        // The number is the one handle everything else in this system
        // takes: `task_assign`, `task_close` and `task_cancel` all address
        // a task by it, `task_progress` asks a worker to report with it,
        // and the group says "#93" out loud. A row without it can be read
        // but not acted on -- you have to go back to the messages to find
        // the number. Sized to the group rather than fixed, so a night of
        // two-digit tasks does not pay for the width of a five-digit one.
        var id_width: usize = 1;
        {
            var widest: u64 = 0;
            for (group.tasks.items) |task| widest = @max(widest, task.id);
            while (widest >= 10) : (widest /= 10) id_width += 1;
        }

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

            // Number first, then progress before the title, so both
            // columns line up and "blocked" can be found by running an eye
            // down one of them -- that is the one a supervisor is looking
            // for.
            const id_text = std.fmt.allocPrint(alloc, "#{d}", .{task.id}) catch "#";
            const pad = @min(id_width -| (id_text.len -| 1), spaces.len);

            const line = std.fmt.allocPrint(alloc, "{s}{s}  {s: <8}  {s}  {s}", .{
                id_text,
                spaces[0..pad],
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

    /// The third tab: what the night was, in numbers.
    ///
    /// **Eight boxes in two columns, and the columns are not arbitrary.**
    /// The left is "does anything need me now" -- what is waiting, where
    /// the talking stopped, who is saying and doing what, who is here. The
    /// right is "what shape did this session have" -- totals, the mix of
    /// tasks, how long they lived, when the hours were busy. Somebody
    /// checking before bed reads the left column twice; the right one is
    /// for the morning.
    ///
    /// Narrower than `two_column_width` the boxes stack in one column in
    /// the same order, because dropping to one column loses nothing but
    /// squeezing two into forty would.
    fn drawStats(self: *Chat, win: vaxis.Window) void {
        if (win.height == 0 or win.width < 8) return;

        if (self.groups.items.len == 0) {
            _ = win.printSegment(.{
                .text = tr("No groups. There will be numbers here once a supervisor makes one."),
                .style = .{ .fg = c_dim, .italic = true },
            }, .{ .row_offset = 0, .col_offset = 0 });
            return;
        }

        const alloc = self.frame.allocator();
        const group = self.groups.items[self.current];

        // The events are the current group's or nobody's: `fetchEvents`
        // throws the previous group's away before it reads. Checked rather
        // than assumed, because a poll can land between the switch and the
        // read, and last group's numbers under this group's name is the
        // one wrong answer here that looks right.
        const mine = std.mem.eql(u8, self.events_group, group.name);
        const events: []const chat_stats.Event = if (mine) self.events.items else &.{};

        var tasks: std.ArrayListUnmanaged(chat_stats.Task) = .empty;
        for (group.tasks.items) |t| tasks.append(alloc, .{
            .id = t.id,
            .title = t.title,
            .owner = t.owner,
            .state = t.state,
        }) catch break;

        var msgs: std.ArrayListUnmanaged(chat_stats.Message) = .empty;
        for (group.messages.items) |m| msgs.append(alloc, .{
            .at_ms = m.at_ms,
            .from = m.from,
            .author = m.author,
            .from_user = m.from_user,
        }) catch break;

        var members: std.ArrayListUnmanaged(chat_stats.Member) = .empty;
        for (group.members.items) |m| members.append(alloc, .{
            .id = m.id,
            .title = m.title,
        }) catch break;

        const s = chat_stats.compute(alloc, .{
            .now_ms = nowMs(self.io),
            .stale_ms = stale_ms,
            .events = events,
            .tasks = tasks.items,
            .messages = msgs.items,
            .members = members.items,
            .hour_of = localHour,
        }) catch return;

        if (win.width >= two_column_width) {
            const half = win.width / 2;
            _ = self.drawNowBoxes(win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = half -| 1,
                .height = win.height,
            }), s, events.len > 0);
            _ = self.drawShapeBoxes(win.child(.{
                .x_off = half,
                .y_off = 0,
                .width = win.width -| half,
                .height = win.height,
            }), s, events.len > 0);
            return;
        }

        const used = self.drawNowBoxes(win, s, events.len > 0);
        if (used + 2 >= win.height) return;
        _ = self.drawShapeBoxes(win.child(.{
            .x_off = 0,
            .y_off = used + 1,
            .width = win.width,
            .height = win.height -| (used + 1),
        }), s, events.len > 0);
    }

    /// Where two columns stop fitting. Below this the boxes stack.
    const two_column_width = 76;

    /// The most columns a terminal's name may take before it is cut.
    ///
    /// A tab's title follows whatever is running in it and can be a whole
    /// sentence; past this the row would be a title with a chart squeezed
    /// onto the end of it.
    const max_name_cols = 14;

    /// How long a task has to have been untouched before its row is
    /// marked.
    ///
    /// **A mark, not a verdict**, and this is the number that has to be
    /// looked at with that in mind: twelve hours is long enough that an
    /// ordinary task does not trip it -- the record this was written
    /// against has a median life of two and a half hours -- and short
    /// enough to catch a night that went wrong at two. A standing lease
    /// trips it every time and is meant to; the row says how long, and the
    /// supervisor says what that means.
    const stale_ms: u64 = 12 * 60 * 60 * 1000;

    /// The left column: what might need somebody now.
    ///
    /// Returns how many rows it used, so the one-column layout knows where
    /// the other half starts.
    fn drawNowBoxes(
        self: *Chat,
        win: vaxis.Window,
        s: chat_stats.Stats,
        have_record: bool,
    ) u16 {
        const alloc = self.frame.allocator();
        var y: u16 = 0;

        // **What to do with a tall window.** Every box has a floor and two
        // of them can use whatever is left: the list of open tasks and the
        // list of terminals. Both were pinned at four rows, so on a window
        // twice as tall as it needed to be the panel drew a quarter of what
        // it knew and left the bottom half empty.
        //
        // The floors are the heads, the three lines of "where it stopped",
        // the one line of "terminals", and the three blank rows between boxes
        // -- thirteen in all. The
        // waiting list is served first because it is the one somebody
        // checks before going to bed.
        const spare = win.height -| 13;
        const want_waiting = s.waiting.len +| (if (s.waiting.len > 0) @as(usize, 0) else 1);
        const waiting_rows = @min(want_waiting, @max(spare / 2, 3));
        const speaker_rows = @max(spare -| waiting_rows, 3);

        y = self.statHead(win, y, tr("Waiting on you"));
        if (!have_record) {
            y = statLine(win, y, tr("  The task record has not been read yet."), .{ .fg = c_dim, .italic = true });
        } else if (s.waiting.len == 0) {
            y = statLine(win, y, tr("  Nothing open."), .{ .fg = c_dim, .italic = true });
        } else {
            const shown = @min(s.waiting.len, waiting_rows);

            // Measured before anything is drawn, for the reason the box
            // below is: "22 h 42 min" and "2 h 5 min" are not the same
            // width, so a title that starts right after one starts in a
            // different place on every row.
            var id_w: u16 = 1;
            var silent_w: u16 = 1;
            for (s.waiting[0..shown]) |w| {
                id_w = @max(id_w, columns(num(alloc, w.task)));
                silent_w = @max(silent_w, columns(humanMs(alloc, w.silent_ms)));
            }

            const used = 4 + id_w + 2 + silent_w + 2 +
                columns(tr("with nothing happening"));

            for (s.waiting[0..shown]) |w| {
                if (y >= win.height) break;

                _ = win.printSegment(.{
                    .text = if (w.over) "▓" else "○",
                    .style = .{ .fg = if (w.over) c_alarm else c_dim, .bold = w.over },
                }, .{ .row_offset = y, .col_offset = 1 });

                const line = fill(alloc, tr("#{0}  {1} {2}  {3}"), &.{
                    padLeft(alloc, num(alloc, w.task), id_w),
                    padRight(alloc, humanMs(alloc, w.silent_ms), silent_w),
                    tr("with nothing happening"),
                    clip(w.title, win.width -| used),
                });
                y = statLine(win, y, line, if (w.over) .{} else .{ .fg = c_dim });
            }
            if (s.waiting.len > shown) {
                const more = fill(alloc, tr("  and {0} more still open"), &.{
                    num(alloc, s.waiting.len - shown),
                });
                y = statLine(win, y, more, .{ .fg = c_dim });
            }
        }

        y = self.statHead(win, y +| 1, tr("Where it stopped"));
        {
            // Half an hour to a cell, widened to whatever the column has:
            // a day drawn 48 columns wide in a 90-column pane left half the
            // box empty for no reason.
            const avail: usize = @intCast(win.width -| 8);
            const per: usize = @max(1, @min(3, avail / chat_stats.Silence.day_cells));
            const cells = @min(avail / per, chat_stats.Silence.day_cells);
            y = statLine(win, y, fill(alloc, tr("  a day {0}"), &.{
                dayBar(alloc, s.silence.day, cells, per),
            }), .{ .fg = c_author });

            y = statLine(win, y, fill(alloc, tr("  last message {0} ago"), &.{
                humanMs(alloc, s.silence.since_last_ms),
            }), .{});

            if (s.silence.longest_ms > 0) {
                y = statLine(win, y, fill(
                    alloc,
                    tr("  longest silence {0} (from {1})"),
                    &.{
                        humanMs(alloc, s.silence.longest_ms),
                        formatTime(alloc, s.silence.longest_from_ms),
                    },
                ), .{ .fg = c_dim });
            }
        }

        y = self.statHead(win, y +| 1, tr("Saying · doing"));
        if (s.speakers.len == 0) {
            y = statLine(win, y, tr("  Nobody has been in this group."), .{ .fg = c_dim, .italic = true });
        } else {
            const shown = @min(s.speakers.len, speaker_rows);

            // **Measured, then drawn.** Every column here is as wide as the
            // widest thing that will go in it, and no wider.
            //
            // It used to pad the name with `{s: <10}`, which counts *bytes*
            // -- so a name holding two Chinese characters was padded four
            // columns short of one holding six Latin letters, and the whole
            // row set off from a different place. `chat_layout.zig` opens
            // with this rule and this box broke it: on this terminal a
            // column is a column, and a CJK character occupies two.
            var name_w: u16 = 0;
            var loudest: usize = 1;
            var busiest: usize = 1;
            var said_w: u16 = 1;
            var doing_w: u16 = 1;

            for (s.speakers[0..shown]) |sp| {
                name_w = @max(name_w, columns(clip(sp.title, max_name_cols)));
                loudest = @max(loudest, sp.said);
                busiest = @max(busiest, sp.doing);
                said_w = @max(said_w, columns(num(alloc, sp.said)));
                doing_w = @max(doing_w, columns(num(alloc, sp.doing)));
            }

            // What is left after the fixed parts goes to the two bars,
            // evenly, so they are the same length as each other whatever
            // the names and the numbers came out at. The words themselves
            // are the same on every row, so their width does not have to be
            // measured to keep the rows aligned -- but it does have to be
            // spent, or the bars run off the edge in a language whose word
            // for "said" is longer than this one's.
            const fixed = 2 + name_w + 1 + columns(tr("said")) + 1 + said_w + 1 +
                2 + columns(tr("doing")) + 1 + doing_w + 1;
            const room: usize = @intCast(win.width -| fixed -| 1);
            const width = @min(room / 2, 16);

            for (s.speakers[0..shown]) |sp| {
                if (y >= win.height) break;

                // Two bars, each against its own column's largest, because
                // the two counts are not in the same units -- and reading
                // "said" against "doing" as though they were is the ranking
                // these two columns exist to refuse.
                const line = fill(alloc, tr("  {0} {1} {2} {3}  {4} {5} {6}"), &.{
                    padRight(alloc, clip(sp.title, max_name_cols), name_w),
                    tr("said"),
                    padLeft(alloc, num(alloc, sp.said), said_w),
                    bar(alloc, sp.said * width / loudest, width),
                    tr("doing"),
                    padLeft(alloc, num(alloc, sp.doing), doing_w),
                    bar(alloc, sp.doing * width / busiest, width),
                });
                y = statLine(win, y, line, .{});
            }
            if (s.speakers.len > speaker_rows) {
                const more = fill(alloc, tr("  and {0} more"), &.{
                    num(alloc, s.speakers.len - speaker_rows),
                });
                y = statLine(win, y, more, .{ .fg = c_dim });
            }
        }

        y = self.statHead(win, y +| 1, tr("Terminals"));
        y = statLine(win, y, fill(
            alloc,
            tr("  {0} in the group now, {1} in the record"),
            &.{ num(alloc, s.terminals.now), num(alloc, s.terminals.ever) },
        ), .{});

        return y;
    }

    /// The right column: the shape of the session.
    fn drawShapeBoxes(
        self: *Chat,
        win: vaxis.Window,
        s: chat_stats.Stats,
        have_record: bool,
    ) u16 {
        const alloc = self.frame.allocator();
        var y: u16 = 0;

        // The two charts take whatever is left over. Their floors, plus
        // every other line in this column, come to sixteen rows; anything
        // beyond that is height they can actually use, split between them.
        //
        // **A one-row chart is a sparkline, and a sparkline is what this
        // column had.** Twenty-four buckets an eighth of a row tall says
        // where the shape rises and falls and nothing else -- on a window
        // forty rows deep, with the bottom half blank.
        const spare = win.height -| 16;
        const chart_h: u16 = @intCast(@min(@max(spare / 2, 1), 10));

        y = self.statHead(win, y, tr("This session"));
        {
            if (s.session.started_ms > 0) {
                y = statLine(win, y, fill(
                    alloc,
                    tr("  first line {0} · {1} since · {2} messages"),
                    &.{
                        formatStamp(alloc, s.session.started_ms),
                        humanMs(alloc, @intCast(@max(
                            nowMs(self.io) - s.session.started_ms,
                            0,
                        ))),
                        num(alloc, s.session.messages),
                    },
                ), .{});
            }

            if (have_record) {
                y = statLine(win, y, fill(
                    alloc,
                    tr("  made {0} · closed {1} · cancelled {2} · open {3}"),
                    &.{
                        num(alloc, s.session.created),
                        num(alloc, s.session.closed),
                        num(alloc, s.session.cancelled),
                        num(alloc, s.session.open),
                    },
                ), .{});

                // Two facts that are only worth anything as a pair. On the
                // record this was written against it read "24 / 71": most
                // tasks never reported at all, which a chart of progress
                // states would have drawn as a queue nobody was working.
                y = statLine(win, y, fill(
                    alloc,
                    tr("  {0} handed round · {1} progress reports / {2}"),
                    &.{
                        num(alloc, s.session.reassigned),
                        num(alloc, s.session.progressed),
                        num(alloc, s.session.tasks_total),
                    },
                ), .{ .fg = c_dim });
            } else {
                y = statLine(win, y, tr("  The task record has not been read yet."), .{ .fg = c_dim, .italic = true });
            }
        }

        y = self.statHead(win, y +| 1, tr("Task mix"));
        {
            var over: usize = 0;
            for (s.waiting) |w| {
                if (w.over) over += 1;
            }
            const total = s.session.tasks_total;
            if (total == 0) {
                y = statLine(win, y, tr("  No tasks in this group yet."), .{ .fg = c_dim, .italic = true });
            } else {
                const width: usize = @intCast(win.width -| 12);
                const closed_w = s.session.closed * width / total;
                const over_w = over * width / total;
                const open_w = (s.session.open -| over) * width / total;

                // **The bar and its key are drawn from one list**, so a
                // colour cannot be right in one of them and wrong in the
                // other. It was: the bar took the default foreground and
                // the whole key line was dimmed, so the same `█` was white
                // above and grey below, and the three segments -- closed,
                // past the mark, still open -- were told apart only by the
                // shade of the glyph.
                //
                // The colours carry the meaning now: `c_alarm` appears
                // here and in the waiting list and nowhere else, so red on
                // this page always means the same thing.
                const closed_style: vaxis.Style = .{ .fg = c_author };
                const over_style: vaxis.Style = .{ .fg = c_alarm };
                const open_style: vaxis.Style = .{ .fg = c_dim };

                y = statSegments(win, y, &.{
                    .{ .text = "  ", .style = .{} },
                    .{ .text = repeat(alloc, "█", closed_w), .style = closed_style },
                    .{ .text = repeat(alloc, "▓", over_w), .style = over_style },
                    .{ .text = repeat(alloc, "░", open_w), .style = open_style },
                    .{ .text = std.fmt.allocPrint(alloc, "  {d}", .{total}) catch "", .style = .{} },
                });

                y = statSegments(win, y, &.{
                    .{ .text = "  █ ", .style = closed_style },
                    .{
                        .text = fill(alloc, tr("closed {0}"), &.{num(alloc, s.session.closed)}),
                        .style = .{ .fg = c_dim },
                    },
                    .{ .text = "  ▓ ", .style = over_style },
                    .{
                        .text = fill(alloc, tr("past the mark {0}"), &.{num(alloc, over)}),
                        .style = .{ .fg = c_dim },
                    },
                    .{ .text = "  ░ ", .style = open_style },
                    .{
                        .text = fill(alloc, tr("open {0}"), &.{num(alloc, s.session.open)}),
                        .style = .{ .fg = c_dim },
                    },
                    .{ .text = "  ✗ ", .style = .{ .fg = c_dim } },
                    .{
                        .text = fill(alloc, tr("cancelled {0}"), &.{num(alloc, s.session.cancelled)}),
                        .style = .{ .fg = c_dim },
                    },
                });
            }
        }

        y = self.statHead(win, y +| 1, tr("How long tasks lived"));
        if (s.life.counted == 0) {
            y = statLine(win, y, tr("  Nothing has been closed yet."), .{ .fg = c_dim, .italic = true });
        } else {
            var widened: [chat_stats.Life.buckets_len]u32 = undefined;
            for (s.life.buckets, 0..) |v, i| widened[i] = v;
            y = drawBars(alloc, win, y, chart_h, &widened, .{ .fg = c_author });

            y = statLine(win, y, fill(
                alloc,
                tr("  fastest {0} · median {1} · slowest {2} (over {3})"),
                &.{
                    humanMs(alloc, s.life.fastest_ms),
                    humanMs(alloc, s.life.median_ms),
                    humanMs(alloc, s.life.slowest_ms),
                    num(alloc, s.life.counted),
                },
            ), .{ .fg = c_dim });
        }

        y = self.statHead(win, y +| 1, tr("Rhythm"));
        {
            y = drawBars(alloc, win, y, chart_h, &s.rhythm.hours, .{ .fg = c_author });

            // The scale under the bars rather than around them, so the bars
            // start at the same column the other chart's do.
            y = statLine(win, y, fill(
                alloc,
                tr("  00:00{0}23:00"),
                &.{spaces[0..@min(@as(usize, @intCast(win.width -| 12)), spaces.len)]},
            ), .{ .fg = c_dim });

            y = statLine(win, y, fill(
                alloc,
                tr("  busiest {0}:00 ({1} messages)"),
                &.{
                    std.fmt.allocPrint(alloc, "{d:0>2}", .{s.rhythm.busiest}) catch "",
                    num(alloc, s.rhythm.busiest_count),
                },
            ), .{ .fg = c_dim });
        }

        return y;
    }

    /// A bar chart, `height` rows tall, one bar per value.
    ///
    /// **Eighths, not rows.** A terminal cell can be an eighth full through
    /// to completely full (`▁` … `█`), so a chart `h` rows tall has `8h`
    /// levels rather than `h` of them. That is what makes three rows worth
    /// drawing at all: at one level per row, a bucket holding a fifth of
    /// the tallest would round to nothing and the chart would say the hour
    /// was empty when it was not.
    ///
    /// Returns the row after the chart, the same as `statLine`.
    fn drawBars(
        alloc: Allocator,
        win: vaxis.Window,
        y: u16,
        height: u16,
        values: []const u32,
        style: vaxis.Style,
    ) u16 {
        if (height == 0 or values.len == 0) return y;
        if (y >= win.height) return y;

        var tallest: u32 = 0;
        for (values) |v| tallest = @max(tallest, v);
        if (tallest == 0) return y;

        const avail: usize = @intCast(win.width -| 4);
        const per: usize = @max(1, @min(3, avail / values.len));
        const shown = @min(values.len, avail / per);

        var row: u16 = 0;
        while (row < height and y + row < win.height) : (row += 1) {
            // Top row first, because that is the order they are drawn in;
            // `below` is how many whole rows sit under this one.
            const below: u32 = height - 1 - row;

            // **The frame arena, never a stack buffer.** vaxis keeps the
            // slice it is handed rather than copying it, so a line written
            // into a local array is read back after this function has
            // returned and its stack has been reused -- which draws
            // whatever happens to be there now. The comment on `frame` says
            // exactly this, having been written the first time it happened;
            // it happened again here, and the screen filled with fragments
            // of other people's strings.
            var line: std.ArrayListUnmanaged(u8) = .empty;
            line.appendSlice(alloc, "  ") catch break;

            for (values[0..shown]) |v| {
                const eighths: u32 = @intCast(
                    @as(u64, v) * height * 8 / tallest,
                );
                const here = std.math.clamp(
                    @as(i64, eighths) - @as(i64, below) * 8,
                    0,
                    8,
                );

                const glyph = if (here == 0)
                    " "
                else
                    spark_glyphs[@intCast(here - 1)];

                for (0..per) |_| line.appendSlice(alloc, glyph) catch break;
            }

            _ = win.printSegment(.{
                .text = line.items,
                .style = style,
            }, .{ .row_offset = y + row, .col_offset = 0 });
        }

        return y + row;
    }

    /// One box's heading, with a rule to the right of it.
    fn statHead(self: *Chat, win: vaxis.Window, y: u16, text: []const u8) u16 {
        if (y >= win.height) return y;
        const alloc = self.frame.allocator();

        _ = win.printSegment(.{
            .text = text,
            .style = .{ .fg = c_title, .bold = true },
        }, .{ .row_offset = y, .col_offset = 1 });

        const used = measure(text) + 2;
        if (used < win.width) {
            _ = win.printSegment(.{
                .text = repeat(alloc, "─", win.width - used - 1),
                .style = .{ .fg = c_frame },
            }, .{ .row_offset = y, .col_offset = used + 1 });
        }
        return y + 1;
    }

    /// One piece of a row: some text and the style it is drawn in.
    const Piece = struct { text: []const u8, style: vaxis.Style };

    /// One line of a box, drawn in pieces so that parts of it can differ.
    ///
    /// Each piece is clipped to what is left of the row, so a long one
    /// stops at the edge instead of wrapping -- `statLine` says why that
    /// matters: a wrapped line silently takes two rows and every box below
    /// it is then drawn one row off.
    fn statSegments(win: vaxis.Window, y: u16, pieces: []const Piece) u16 {
        if (y >= win.height) return y;

        var col: u16 = 0;
        for (pieces) |p| {
            if (col + 1 >= win.width) break;

            const text = clip(p.text, win.width -| col -| 1);
            if (text.len == 0) continue;

            _ = win.printSegment(.{
                .text = text,
                .style = p.style,
            }, .{ .row_offset = y, .col_offset = col });

            col += columns(text);
        }

        return y + 1;
    }

    /// One line of a box, clipped to the column it belongs to.
    ///
    /// Clipped rather than left to wrap: vaxis wraps inside the window, so
    /// a long line does not spill into the next column -- it silently
    /// takes two rows, and every box below it is then drawn one row off.
    fn statLine(
        win: vaxis.Window,
        y: u16,
        text: []const u8,
        style: vaxis.Style,
    ) u16 {
        if (y >= win.height) return y;
        _ = win.printSegment(.{
            .text = clip(text, win.width -| 1),
            .style = style,
        }, .{ .row_offset = y, .col_offset = 0 });
        return y + 1;
    }

    /// What the tabs are called at this width.
    ///
    /// **One language, not two.** These read "群聊 / CHAT" for as long as
    /// the window was Chinese-only: the English half was there so that
    /// somebody who did not read Chinese could still find the tab. Now that
    /// the window is translated, the pair is redundant in one language and
    /// wrong in every other -- a French reader has no use for either half.
    ///
    /// Padded here rather than in the translation, so a translator cannot
    /// accidentally lose the space that separates one tab from the next.
    fn tabLabels(alloc: Allocator) [3][]const u8 {
        return .{
            std.fmt.allocPrint(alloc, " {s} ", .{tr("Chat")}) catch " Chat ",
            std.fmt.allocPrint(alloc, " {s} ", .{tr("Tasks")}) catch " Tasks ",
            std.fmt.allocPrint(alloc, " {s} ", .{tr("Stats")}) catch " Stats ",
        };
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
        if (std.mem.eql(u8, owner, "0x0000000000000000")) return tr("· unassigned");

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
                .text = tr("No groups. The conversation will appear here once a supervisor makes one."),
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
                .text = tr("── nothing older ──"),
                .kind = .notice,
                .message = 0,
            });
        }

        for (group.messages.items, 0..) |m, mi| {
            const stamp = formatTime(alloc, m.at_ms);
            const header = std.fmt.allocPrint(alloc, "{s}  {s}{s}", .{
                stamp,
                m.author,
                if (m.summary) tr("  (summary)") else "",
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

/// `struct tm` and the call that fills it in, from `os`, which owns the one
/// declaration of both. It used to be redeclared here; that was fine while
/// there was one `localtime_r` in the world, and stopped being fine when
/// Windows turned out to spell it `_localtime64_s` with the arguments the
/// other way round. A copy of a declaration is a copy of a decision.
const Tm = internal_os.Tm;
const localtime_r = internal_os.localtime_r;

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

/// One translated string.
///
/// **Everything a person reads in this window goes through here.** It was
/// all written as Chinese literals, which meant the window ignored the
/// language the rest of Polter respects: somebody who had switched to
/// English got an English menu, an English settings page, and a
/// conversations view still in Chinese. There is no per-window setting to
/// find and no bug in the switching -- the strings simply were not
/// translatable.
///
/// The msgid is English, the way every other translatable string in this
/// repository is, and `po/` carries the rest. An untranslated locale falls
/// back to the msgid, which is a readable answer rather than a blank.
fn tr(comptime msgid: [:0]const u8) []const u8 {
    return std.mem.span(internal_os.i18n._(msgid.ptr));
}

/// A translated string with values put into it.
///
/// **Why not `std.fmt`.** A format string has to be known at compile time
/// and a translated one is by definition not: it comes out of a `.mo` file
/// at run time. So the placeholders are numbered -- `{0}`, `{1}` -- and
/// filled by substitution, which also lets a translation put them in a
/// different order, and languages do: "3 tasks in 2 groups" and its
/// Chinese counterpart do not put the numbers in the same places.
///
/// Anything that is not a `{digit}` is copied through, so a translation
/// containing braces for other reasons keeps them.
fn fill(alloc: Allocator, template: []const u8, values: []const []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;

    var i: usize = 0;
    while (i < template.len) {
        const rest = template.len - i;
        if (rest >= 3 and
            template[i] == '{' and
            template[i + 2] == '}' and
            template[i + 1] >= '0' and
            template[i + 1] <= '9')
        {
            const at: usize = template[i + 1] - '0';

            // A placeholder the caller did not supply is left as it stands
            // rather than dropped: a visible `{3}` is a translation to fix,
            // and a silent gap is a sentence that reads as though it were
            // written that way.
            if (at < values.len) {
                out.appendSlice(alloc, values[at]) catch return template;
                i += 3;
                continue;
            }
        }

        out.append(alloc, template[i]) catch return template;
        i += 1;
    }

    return out.items;
}

/// One number as text, for `fill`.
fn num(alloc: Allocator, v: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{v}) catch "?";
}

/// The wall clock in milliseconds.
///
/// Wall rather than the loop's awake clock: everything it is compared
/// against -- a message's `at_ms`, an event's -- was stamped off the real
/// clock, and a machine that spent four hours suspended would otherwise
/// report the night as four hours shorter than it was.
fn nowMs(io: std.Io) i64 {
    const wall: std.Io.Timestamp = .now(io, .real);
    return @intCast(@divFloor(wall.nanoseconds, std.time.ns_per_ms));
}

/// The local hour of the day, or 24 for "cannot tell".
///
/// Twenty-four rather than zero, because zero is a real hour: a machine
/// whose libc would not answer would otherwise pile every message it could
/// not place onto midnight and report the night's busiest hour as 00:00.
fn localHour(at_ms: i64) u8 {
    if (at_ms <= 0) return 24;
    const secs: i64 = @divTrunc(at_ms, std.time.ms_per_s);
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return 24;
    return @intCast(@mod(tm.hour, 24));
}

/// `MM-DD HH:MM` in the reader's own timezone.
fn formatStamp(alloc: Allocator, at_ms: i64) []const u8 {
    if (at_ms <= 0) return "";

    const secs: i64 = @divTrunc(at_ms, std.time.ms_per_s);
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return "";

    return std.fmt.allocPrint(alloc, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(@mod(tm.mon + 1, 13))),
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(@mod(tm.hour, 24))),
        @as(u32, @intCast(@mod(tm.min, 60))),
    }) catch "";
}

/// A duration as somebody would say it out loud.
///
/// Coarse on purpose: the difference between 49 and 50 hours changes
/// nothing anybody would do, and a row that reported it to the minute
/// would be asking to be read as a measurement rather than as a rough
/// shape. Whole units all the way up, and never more than two of them.
fn humanMs(alloc: Allocator, ms: u64) []const u8 {
    const secs = ms / 1000;
    if (secs < 60) return tr("under a minute");

    const mins = secs / 60;
    if (mins < 60) return fill(alloc, tr("{0} min"), &.{num(alloc, mins)});

    const hours = mins / 60;
    if (hours < 48) {
        const rest = mins % 60;
        if (rest == 0) return fill(alloc, tr("{0} h"), &.{num(alloc, hours)});
        return fill(alloc, tr("{0} h {1} min"), &.{ num(alloc, hours), num(alloc, rest) });
    }

    const days = hours / 24;
    const rest = hours % 24;
    if (rest == 0) return fill(alloc, tr("{0} d"), &.{num(alloc, days)});
    return fill(alloc, tr("{0} d {1} h"), &.{ num(alloc, days), num(alloc, rest) });
}

/// `text` cut to `width` display columns.
///
/// By column and never mid-character: a line cut inside a multi-byte
/// character is not a shorter line, it is a broken one, and the terminal
/// draws the replacement glyph. The same rule `chat_layout.wrap` keeps,
/// for the same reason.
fn clip(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (columns(text) <= width) return text;

    var used: u16 = 0;
    var end: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const w = columns(slice);
        if (used + w > width) break;
        used += w;
        end += slice.len;
    }
    return text[0..end];
}

/// What a string will occupy on this terminal, in columns.
///
/// The same measurement `Chat.measure` makes; this is the one the helpers
/// below a `Chat` can reach.
fn columns(text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, .unicode);
}

/// `text` padded with spaces on the right to `cols` display columns.
///
/// **Columns, not bytes.** `{s: <10}` pads to ten bytes, which is ten
/// columns only for text that happens to be all ASCII -- a name with two
/// CJK characters in it is six bytes and four columns, and padding it by
/// bytes leaves the row starting from a different place than its
/// neighbours. That is what made the two-column box ragged.
fn padRight(alloc: Allocator, text: []const u8, cols: u16) []const u8 {
    const have = columns(text);
    if (have >= cols) return text;

    const gap = @min(@as(usize, cols - have), spaces.len);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ text, spaces[0..gap] }) catch text;
}

/// The same, on the left, for numbers.
fn padLeft(alloc: Allocator, text: []const u8, cols: u16) []const u8 {
    const have = columns(text);
    if (have >= cols) return text;

    const gap = @min(@as(usize, cols - have), spaces.len);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ spaces[0..gap], text }) catch text;
}

/// One glyph repeated, `n` times.
fn repeat(alloc: Allocator, glyph: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    const capped = @min(n, 120);
    const out = alloc.alloc(u8, glyph.len * capped) catch return "";
    for (0..capped) |i| @memcpy(out[i * glyph.len ..][0..glyph.len], glyph);
    return out;
}

/// A bar `width` cells wide with `filled` of them solid.
fn bar(alloc: Allocator, filled: usize, width: usize) []const u8 {
    const on = @min(filled, width);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{
        repeat(alloc, "█", on),
        repeat(alloc, "░", width - on),
    }) catch "";
}

/// The last day, one cell per half hour, newest on the right.
///
/// Sampled rather than scaled when the column is narrow: each cell of the
/// drawing takes the *or* of the cells it covers, so a half hour somebody
/// said something in never disappears into a rounding. A gap that is not
/// really there is the failure mode worth avoiding here -- it is the one
/// that would have somebody get up in the night.
fn dayBar(
    alloc: Allocator,
    day: [chat_stats.Silence.day_cells]bool,
    cells: usize,
    per: usize,
) []const u8 {
    if (cells == 0 or per == 0) return "";
    const width = @min(cells, chat_stats.Silence.day_cells);

    // Each drawn cell covers its own share of the day, worked out from
    // both ends rather than from a width per cell. Dividing first and
    // stepping by the result loses whatever does not divide evenly -- and
    // what it loses is the *end* of the range, which here is the last few
    // hours: the one part of the day somebody checking at three in the
    // morning is actually looking at.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (0..width) |i| {
        const from = i * chat_stats.Silence.day_cells / width;
        const to = @max(from + 1, (i + 1) * chat_stats.Silence.day_cells / width);

        var any = false;
        for (day[from..@min(to, chat_stats.Silence.day_cells)]) |on| any = any or on;
        for (0..per) |_| {
            out.appendSlice(alloc, if (any) "█" else "░") catch return out.items;
        }
    }
    return out.items;
}

/// The eight heights a sparkline is drawn with.
const spark_glyphs = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// A sparkline, scaled to its own tallest bar.
///
/// Scaled to itself rather than to a fixed ceiling, because what these are
/// read for is where the shape rises and falls -- and a shared scale would
/// flatten a quiet group into a straight line at the bottom.
fn sparkU32(alloc: Allocator, values: []const u32) []const u8 {
    if (values.len == 0) return "";

    var tallest: u32 = 0;
    for (values) |v| tallest = @max(tallest, v);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (values) |v| {
        // Zero is the floor glyph, not the first step above it: a bucket
        // nothing landed in has to look different from the smallest one
        // that something did.
        const level: usize = if (tallest == 0 or v == 0)
            0
        else
            1 + (v - 1) * (spark_glyphs.len - 2) / @max(tallest - 1, 1);

        out.appendSlice(alloc, spark_glyphs[@min(level, spark_glyphs.len - 1)]) catch break;
    }
    return out.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    _ = layout;
    _ = chat_stats;
}

test "the last hours of the day survive a narrow column" {
    // The failure this is written from: dividing forty-eight half hours
    // into a forty-cell column and stepping by the quotient drew the first
    // forty and dropped the last eight -- four hours of "nothing was said"
    // that had in fact just happened.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var day: [chat_stats.Silence.day_cells]bool = @splat(false);
    day[chat_stats.Silence.day_cells - 1] = true;

    const drawn = dayBar(alloc, day, 40, 1);
    try testing.expect(std.mem.endsWith(u8, drawn, "█"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, drawn, "█"));

    // And a full-width column is one cell to one half hour.
    const wide = dayBar(alloc, day, chat_stats.Silence.day_cells, 1);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, wide, "█"));
    try testing.expect(std.mem.endsWith(u8, wide, "█"));
}

test "a sparkline keeps an empty bucket different from the smallest full one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const drawn = sparkU32(alloc, &.{ 0, 1, 8 });

    // Three glyphs, three bytes each, and the first is the floor.
    try testing.expect(std.mem.startsWith(u8, drawn, "▁"));
    try testing.expect(!std.mem.startsWith(u8, drawn[3..], "▁"));
    try testing.expect(std.mem.endsWith(u8, drawn, "█"));
}

test "a duration is said the way somebody would say it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The msgids, because a test process has no locale bound and `t`
    // hands back what it was given. That is the fallback every
    // untranslated language gets too, so this is also a check that the
    // fallback reads as a sentence rather than as a template.
    try testing.expectEqualStrings("under a minute", humanMs(alloc, 30 * 1000));
    try testing.expectEqualStrings("42 min", humanMs(alloc, 42 * 60 * 1000));
    try testing.expectEqualStrings("3 h", humanMs(alloc, 3 * 60 * 60 * 1000));
    try testing.expectEqualStrings("3 h 40 min", humanMs(alloc, (3 * 60 + 40) * 60 * 1000));
    try testing.expectEqualStrings("2 d 1 h", humanMs(alloc, 49 * 60 * 60 * 1000));
}

test "clipping counts columns, and never cuts a character in half" {
    // A CJK character is two columns and three bytes, and the bug this
    // guards is cutting between the two: the terminal draws the
    // replacement glyph, which is wider than what it replaced.
    try testing.expectEqualStrings("真机", clip("真机批次三", 4));
    try testing.expectEqualStrings("真机", clip("真机批次三", 5));
    try testing.expectEqualStrings("真机批", clip("真机批次三", 6));
    try testing.expectEqualStrings("", clip("真机", 1));
    try testing.expectEqualStrings("abc", clip("abc", 8));
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

test "a tab is named once, in one language" {
    // These read "群聊 / CHAT" while the window was Chinese-only: the
    // English half was there so somebody who could not read the Chinese
    // could still find the tab. Once the window is translated that pair is
    // redundant in one language and wrong in every other -- a French reader
    // has no use for either half.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const labels = Chat.tabLabels(arena.allocator());

    // No locale is bound in a test process, so what comes back is the
    // msgid -- which is also what an untranslated language gets.
    try testing.expectEqualStrings(" Chat ", labels[0]);
    try testing.expectEqualStrings(" Tasks ", labels[1]);
    try testing.expectEqualStrings(" Stats ", labels[2]);

    // The padding is ours rather than the translation's, so a translator
    // cannot lose the space that separates one tab from the next.
    for (labels) |l| {
        try testing.expect(std.mem.startsWith(u8, l, " "));
        try testing.expect(std.mem.endsWith(u8, l, " "));
    }
}

test "a translation puts the values where its own grammar wants them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings(
        "made 71 · closed 60",
        fill(alloc, "made {0} · closed {1}", &.{ "71", "60" }),
    );

    // The reason the placeholders are numbered rather than positional:
    // a translation may need them the other way round.
    try testing.expectEqualStrings(
        "60 closed of 71",
        fill(alloc, "{1} closed of {0}", &.{ "71", "60" }),
    );

    // A placeholder nobody supplied stays visible -- a translation to fix,
    // rather than a sentence with a silent hole in it.
    try testing.expectEqualStrings(
        "one 1 and {3}",
        fill(alloc, "one {0} and {3}", &.{"1"}),
    );

    // And a brace that is not a placeholder is left alone.
    try testing.expectEqualStrings(
        "{} {a} 1",
        fill(alloc, "{} {a} {0}", &.{"1"}),
    );
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
