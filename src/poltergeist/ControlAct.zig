//! What the person does in the control room: one request, checked against
//! what is true now, and carried out or refused by name.
//!
//! **A click is aimed at what was on screen when it was made**, and that
//! may no longer be there. So a request that would press a key in somebody
//! else's terminal hands back the two moments the row was drawn from --
//! `since_ms` and `event_ms`, both in the snapshot -- and nothing is sent
//! unless they still hold (dev-docs/poltergeist/control-room.md, 7.1). A
//! refusal sends no key at all, not the first half of one.
//!
//! **Who is asking is not in the request.** This is reached through
//! `ghostty_app_control_act`, which only the host can call, from the window
//! the person is looking at; there is no field a caller could fill in to
//! claim to be them.
//!
//! ## The request
//!
//! ```
//! {"act":"seen",     "group":"web-app"}
//! {"act":"seen",     "terminal":"0x…"}                  a terminal in no group
//! {"act":"snooze",   "group":"web-app"}                 until it changes
//! {"act":"snooze",   "group":"web-app","until_ms":N}    until then (wall)
//! {"act":"unsnooze", "group":"web-app"}
//! {"act":"approve",  "terminal":"0x…","since_ms":N,"event_ms":N}
//! {"act":"refuse",   "terminal":"0x…","since_ms":N,"event_ms":N}
//! {"act":"reply",    "terminal":"0x…","since_ms":N,"text":"…"}
//! {"act":"new_group","name":"web-app"}
//! {"act":"start_supervisor","group":"web-app"}          the snapshot's role
//!                                                       and directory
//! {"act":"start_supervisor","group":"web-app","role":"…","cwd":"/…"}
//! {"act":"start_supervisor","group":"web-app","session":"new"}
//!                                                       last | new
//! ```
//!
//! `start_supervisor` opens a tab, starts the role's CLI in it, and holds
//! "this terminal is `group`'s supervisor" for the agent that connects from
//! it.
//!
//! `session` says whether it goes on with the session the group's last
//! supervisor was in. **`last` is what leaving it out means, and it is a
//! preference, not a condition**: the session is gone on with when the
//! snapshot's `supervisor.resume.can` holds at that moment *for the role
//! this start uses* -- there is a session written down, the role starts
//! the same CLI, that CLI's adapter says it can, and no open terminal is
//! in it -- and a new session is started otherwise. A supervisor that
//! cannot go on where the last one stopped is still a supervisor; a group
//! left without one because of it would be the worse answer. What the
//! control room offered is `resume` in the snapshot, with the reason when
//! it is no. `new` starts a new session whatever is written down.
//!
//! The start is the same act either way. **It returns when the tab has been asked for, not when there is a
//! supervisor**: what becomes of it is the group's `supervisor` in the
//! snapshot (`starting`, then `present` or `failed`). A refusal below means
//! nothing was started.
//!
//! ## The refusals
//!
//! | act | refused with | when |
//! |---|---|---|
//! | any | `BadRequest` | not JSON, no such `act`, a field missing or of the wrong type |
//! | seen, snooze, unsnooze | `NoSuchGroup` | the group is not there |
//! | seen (a terminal) | `UnknownTerminal` | the terminal is not there |
//! | snooze | `SnoozeInThePast` | `until_ms` is not after now |
//! | approve, refuse, reply | `UnknownTerminal` | the terminal is not there |
//! | approve, refuse | `PromptGone` | it is not waiting on an approval; or `since_ms` / `event_ms` are not the ones it has now; or its screen has moved since the box was drawn |
//! | reply | `NothingToReplyTo` | it is not waiting on an answer, finished, or failed -- a box or a turn in progress is not somewhere to type a sentence |
//! | reply | `Stale` | `since_ms` is not the one it has now |
//! | reply | `EmptyText` | nothing but whitespace |
//! | approve, refuse, reply | `UserPresent` | a key reached that terminal in the last ten seconds |
//! | approve, refuse, reply | `DraftInLine` | there is unsubmitted text in its input line |
//! | approve, refuse, reply | `ChildExited` | its process has ended |
//! | approve, refuse | `KeyFailed` | the key did not reach the program |
//! | new_group | `BadName` | the name is empty, longer than 48, or has anything but `a-z`, `0-9` and `-` in it |
//! | new_group | `GroupExists` | there is one by that name |
//! | new_group | `TooManyGroups` | the list is full |
//! | start_supervisor | `NoSuchGroup` | the group is not there |
//! | start_supervisor | `HasSupervisor` | it has one |
//! | start_supervisor | `AlreadyStarting` | one is on its way |
//! | start_supervisor | `NoSupervisorRole` | no role was named and there is none to default to |
//! | start_supervisor | `NoSuchPersona`, `NotASupervisorRole`, `NoCli` | the role named is not there, does not make a supervisor, or has no CLI to start |
//! | start_supervisor | `NotAbsolute`, `NoSuchDirectory`, `NotADirectory` | the directory |
//! | start_supervisor | `OpenFailed` | no tab could be opened |
//!
//! The last four are the terminal's own, from the path every agent's text
//! takes; they are not decided here.

const ControlAct = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");

pub const Id = Bus.Id;

pub const Prompt = struct {
    terminal: Id,
    since_ms: u64,
    event_ms: u64,
};

pub const Act = union(enum) {
    seen: []const u8,
    /// The person looked at the row of a terminal that is in no group.
    seen_terminal: Id,
    snooze: struct { group: []const u8, until_ms: ?u64 },
    unsnooze: []const u8,
    approve: Prompt,
    refuse: Prompt,
    reply: struct { terminal: Id, since_ms: u64, text: []const u8 },
    new_group: []const u8,
    /// Empty `role` and `cwd` are "the one the snapshot names".
    start_supervisor: struct { group: []const u8, role: []const u8, cwd: []const u8, session: Session },
};

/// Which session a supervisor is started in.
pub const Session = enum {
    /// The last supervisor's, when it can be gone on with; a new one
    /// otherwise.
    last,
    /// A new one, whatever is written down.
    new,
};

pub const Refusal = error{
    BadRequest,
    NoSuchGroup,
    SnoozeInThePast,
    UnknownTerminal,
    PromptGone,
    NothingToReplyTo,
    Stale,
    EmptyText,
    BadName,
    GroupExists,
    HasSupervisor,
    AlreadyStarting,
};

/// The keys an approval and a refusal are. One key each, and neither
/// counts options: return takes the one highlighted, escape declines.
pub const approve_key = "enter";
pub const refuse_key = "escape";

/// What carrying an act out needs from outside this file.
pub const Host = struct {
    ctx: *anyopaque,
    /// Press one key in a terminal, through the guards an agent's key goes
    /// through, and fail unless it reached the program.
    sendKey: *const fn (ctx: *anyopaque, id: Id, key: []const u8) anyerror!void,
    /// Type a line into a terminal and submit it, through the same guards.
    sendText: *const fn (ctx: *anyopaque, id: Id, text: []const u8) anyerror!void,
    /// Write a group's marks down.
    persist: *const fn (ctx: *anyopaque, group: []const u8, marks: Chat.Marks) void,
    /// Make a group, the way the person makes one anywhere else: they are
    /// in it, and it is written down so it is there in the morning.
    createGroup: *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
    /// The terminal that is this group's supervisor, as the snapshot says
    /// it; null when it has none.
    stewardOf: *const fn (ctx: *anyopaque, group: []const u8) ?Id,
    /// Open a tab and start a supervisor for `group` in it. Empty `role`
    /// and `cwd` are the snapshot's.
    startSupervisor: *const fn (ctx: *anyopaque, group: []const u8, role: []const u8, cwd: []const u8, session: Session) anyerror!void,
};

fn fieldOf(obj: std.json.ObjectMap, name: []const u8) Refusal!std.json.Value {
    return obj.get(name) orelse error.BadRequest;
}

fn textOf(obj: std.json.ObjectMap, name: []const u8) Refusal![]const u8 {
    return switch (try fieldOf(obj, name)) {
        .string => |s| s,
        else => error.BadRequest,
    };
}

fn msOf(obj: std.json.ObjectMap, name: []const u8) Refusal!u64 {
    return switch (try fieldOf(obj, name)) {
        .integer => |n| if (n >= 0) @intCast(n) else error.BadRequest,
        else => error.BadRequest,
    };
}

fn idOf(obj: std.json.ObjectMap, name: []const u8) Refusal!Id {
    const s = try textOf(obj, name);
    if (s.len != 18 or !std.mem.startsWith(u8, s, "0x")) return error.BadRequest;
    return std.fmt.parseInt(u64, s[2..], 16) catch error.BadRequest;
}

/// Read a request. What it returns borrows from `arena`.
pub fn parse(arena: Allocator, json: []const u8) (Refusal || Allocator.Error)!Act {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRequest,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadRequest,
    };

    const Name = enum { seen, snooze, unsnooze, approve, refuse, reply, new_group, start_supervisor };
    const name = std.meta.stringToEnum(Name, try textOf(obj, "act")) orelse return error.BadRequest;
    return switch (name) {
        // One or the other: a row is a group's or a lone terminal's.
        .seen => if (obj.get("terminal")) |_|
            (if (obj.get("group")) |_| return error.BadRequest else .{ .seen_terminal = try idOf(obj, "terminal") })
        else
            .{ .seen = try textOf(obj, "group") },
        .unsnooze => .{ .unsnooze = try textOf(obj, "group") },
        .snooze => .{ .snooze = .{
            .group = try textOf(obj, "group"),
            .until_ms = if (obj.get("until_ms")) |v| switch (v) {
                .null => null,
                else => try msOf(obj, "until_ms"),
            } else null,
        } },
        .approve => .{ .approve = try promptOf(obj) },
        .refuse => .{ .refuse = try promptOf(obj) },
        .reply => .{ .reply = .{
            .terminal = try idOf(obj, "terminal"),
            .since_ms = try msOf(obj, "since_ms"),
            .text = try textOf(obj, "text"),
        } },
        .new_group => .{ .new_group = try textOf(obj, "name") },
        .start_supervisor => .{
            .start_supervisor = .{
                .group = try textOf(obj, "group"),
                .role = if (obj.get("role")) |_| try textOf(obj, "role") else "",
                .cwd = if (obj.get("cwd")) |_| try textOf(obj, "cwd") else "",
                // A word that is neither is not a request: guessing which was
                // meant would start the session the person did not ask for.
                .session = if (obj.get("session")) |_|
                    std.meta.stringToEnum(Session, try textOf(obj, "session")) orelse return error.BadRequest
                else
                    .last,
            },
        },
    };
}

fn promptOf(obj: std.json.ObjectMap) Refusal!Prompt {
    return .{
        .terminal = try idOf(obj, "terminal"),
        .since_ms = try msOf(obj, "since_ms"),
        .event_ms = try msOf(obj, "event_ms"),
    };
}

/// Carry one act out, or refuse it. `now_ms` is the bus's clock, `wall_ms`
/// the real one.
pub fn perform(
    act: Act,
    bus: *Bus,
    chat: *Chat,
    host: Host,
    now_ms: u64,
    wall_ms: u64,
) anyerror!void {
    switch (act) {
        .seen => |group| {
            chat.markSeen(group, now_ms, wall_ms) catch return error.NoSuchGroup;
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        // Nothing to write down: the mark is the terminal's, and a
        // terminal's id does not outlive the run (`Bus.Entry.seen_ms`).
        .seen_terminal => |id| if (!bus.markSeen(id, now_ms)) return error.UnknownTerminal,
        .snooze => |s| {
            if (!chat.exists(s.group)) return error.NoSuchGroup;
            const snooze: Chat.Marks.Snooze = if (s.until_ms) |until| until: {
                if (until <= wall_ms) return error.SnoozeInThePast;
                break :until .{ .until = .{ .at_ms = wall_ms, .until_ms = until } };
            } else .{ .next_event = wall_ms };
            try chat.setSnooze(s.group, snooze, now_ms);
            host.persist(host.ctx, s.group, try chat.marksOf(s.group));
        },
        .unsnooze => |group| {
            chat.setSnooze(group, .none, now_ms) catch return error.NoSuchGroup;
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        .approve => |p| {
            try standing(bus, p, now_ms);
            try host.sendKey(host.ctx, p.terminal, approve_key);
        },
        .refuse => |p| {
            try standing(bus, p, now_ms);
            try host.sendKey(host.ctx, p.terminal, refuse_key);
        },
        .reply => |r| {
            const text = std.mem.trim(u8, r.text, " \t\r\n");
            if (text.len == 0) return error.EmptyText;
            const e = bus.get(r.terminal) orelse return error.UnknownTerminal;
            const a = e.agent;
            const open = a.hooks == .live and switch (a.state) {
                .awaiting_input, .ended, .failed => true,
                // A permission box takes keys, not a sentence, and a turn
                // in progress is not waiting to be told anything.
                .awaiting_approval, .in_turn, .idle => false,
            };
            if (!open) return error.NothingToReplyTo;
            if (a.since_ms != r.since_ms) return error.Stale;
            try host.sendText(host.ctx, r.terminal, text);
        },
        .new_group => |raw| {
            // What was typed, less the space round it. Nothing else is
            // done to it: a name that is not allowed is refused and said,
            // not turned into one the person did not type.
            // Whether it is a name, and whether it is taken, are the chat's
            // to say when it makes the group (`Chat.create`).
            const name = std.mem.trim(u8, raw, " \t\r\n");
            try host.createGroup(host.ctx, name);
        },
        .start_supervisor => |s| {
            if (!chat.exists(s.group)) return error.NoSuchGroup;
            if (host.stewardOf(host.ctx, s.group) != null) return error.HasSupervisor;
            // Asked here as well as where the start is recorded, so that a
            // second press is refused before anything is opened for it.
            if (chat.startOf(s.group, now_ms).state == .starting) return error.AlreadyStarting;
            try host.startSupervisor(host.ctx, s.group, s.role, s.cwd, s.session);
        },
    }
}

/// The guard on anything that answers a prompt: the one the person saw is
/// the one still there.
fn standing(bus: *const Bus, p: Prompt, now_ms: u64) Refusal!void {
    if (bus.get(p.terminal) == null) return error.UnknownTerminal;
    if (!bus.promptStanding(p.terminal, p.since_ms, p.event_ms, now_ms)) return error.PromptGone;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const AgentEvent = @import("agent_event.zig");

/// A host that only writes down what it was asked to do.
const Recorder = struct {
    keys: std.ArrayListUnmanaged([]const u8) = .empty,
    texts: std.ArrayListUnmanaged([]const u8) = .empty,
    persisted: std.ArrayListUnmanaged(Chat.Marks) = .empty,
    refuse_with: ?anyerror = null,
    /// The chat a made group goes into, as the real host's does.
    chat: ?*Chat = null,
    steward: ?Id = null,
    started: std.ArrayListUnmanaged(Started) = .empty,

    const Started = struct { group: []const u8, role: []const u8, cwd: []const u8, session: Session };

    fn deinit(self: *Recorder) void {
        self.keys.deinit(testing.allocator);
        self.texts.deinit(testing.allocator);
        self.persisted.deinit(testing.allocator);
        for (self.started.items) |st| {
            testing.allocator.free(st.group);
            testing.allocator.free(st.role);
            testing.allocator.free(st.cwd);
        }
        self.started.deinit(testing.allocator);
    }

    fn host(self: *Recorder) Host {
        return .{
            .ctx = self,
            .sendKey = sendKey,
            .sendText = sendText,
            .persist = persist,
            .createGroup = createGroup,
            .stewardOf = stewardOf,
            .startSupervisor = startSupervisor,
        };
    }

    fn createGroup(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.chat.?.create(name, Chat.user_id);
    }

    fn stewardOf(ctx: *anyopaque, _: []const u8) ?Id {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.steward;
    }

    fn startSupervisor(ctx: *anyopaque, group: []const u8, role: []const u8, cwd: []const u8, session: Session) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        // Copied: the request they point into is gone when the act returns.
        const a = testing.allocator;
        try self.started.append(a, .{ .group = try a.dupe(u8, group), .role = try a.dupe(u8, role), .cwd = try a.dupe(u8, cwd), .session = session });
    }

    fn sendKey(ctx: *anyopaque, _: Id, key: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.keys.append(testing.allocator, key);
    }

    fn sendText(ctx: *anyopaque, _: Id, text: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.texts.append(testing.allocator, text);
    }

    fn persist(ctx: *anyopaque, _: []const u8, marks: Chat.Marks) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.persisted.append(testing.allocator, marks) catch {};
    }
};

const term: Id = 0xa1;
const wall: u64 = 1_700_000_000_000;

const Bench = struct {
    bus: Bus,
    chat: Chat,
    rec: Recorder = .{},

    fn init() !Bench {
        var b: Bench = .{ .bus = .init(testing.allocator, .{}), .chat = .init(testing.allocator, .{}) };
        errdefer b.deinit();
        try b.bus.addSupervisor(term);
        try b.chat.create("web-app", term);
        return b;
    }

    fn deinit(self: *Bench) void {
        self.rec.deinit();
        self.chat.deinit();
        self.bus.deinit();
    }

    fn hook(self: *Bench, kind: AgentEvent.Kind, note: ?[]const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = kind;
        ev.note = note;
        _ = try self.bus.agentEvent(term, ev, at_ms);
    }

    fn act(self: *Bench, json: []const u8, now_ms: u64) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const parsed = try parse(arena.allocator(), json);
        self.rec.chat = &self.chat;
        try perform(parsed, &self.bus, &self.chat, self.rec.host(), now_ms, wall + now_ms);
    }
};

test "ControlRoom act: approving the prompt that is there presses return, once" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);

    try b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.keys.items.len);
    try testing.expectEqualStrings("enter", b.rec.keys.items[0]);
    try testing.expectEqual(@as(usize, 0), b.rec.texts.items.len);
}

test "ControlRoom act: refusing presses escape" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);

    try b.act(
        \\{"act":"refuse","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.keys.items.len);
    try testing.expectEqualStrings("escape", b.rec.keys.items[0]);
}

test "ControlRoom act: the prompt has changed, so no key is sent" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);
    // The row was drawn. Then a different box took its place.
    try b.hook(.awaiting_approval, "Bash(git push --force)", 4_000);

    const seen_then =
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    ;
    try testing.expectError(error.PromptGone, b.act(seen_then, 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    // Refusing what is no longer there is refused the same way.
    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"refuse","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom act: a prompt that was answered already takes no key" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(x)", 1_000);
    // It went on with its turn.
    try b.hook(.turn_started, null, 2_000);

    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    // Not even with the moments it has now: it is not waiting on a box.
    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":2000,"event_ms":2000}
    , 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    try testing.expectError(error.UnknownTerminal, b.act(
        \\{"act":"approve","terminal":"0x00000000000000ff","since_ms":1000,"event_ms":1000}
    , 5_000));
}

test "ControlRoom act: what the terminal refuses is the answer, by its own name" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(x)", 1_000);

    b.rec.refuse_with = error.DraftInLine;
    try testing.expectError(error.DraftInLine, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    b.rec.refuse_with = error.UserPresent;
    try b.hook(.awaiting_input, "which?", 6_000);
    try testing.expectError(error.UserPresent, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":6000,"text":"the second"}
    , 7_000));
}

test "ControlRoom act: a reply goes to an agent that is waiting to be told something" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_input, "which format?", 1_000);

    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"  the second one\n"}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.texts.items.len);
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    // Said again by the agent: the same wait, and still answerable.
    try b.hook(.awaiting_input, "which format?", 6_000);
    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"the second"}
    , 7_000);
    try testing.expectEqual(@as(usize, 2), b.rec.texts.items.len);
}

test "ControlRoom act: a reply is not typed into a box, a turn, or a state that has moved on" {
    var b = try Bench.init();
    defer b.deinit();

    try b.hook(.awaiting_approval, "Bash(x)", 1_000);
    try testing.expectError(error.NothingToReplyTo, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"yes"}
    , 2_000));

    try b.hook(.turn_started, null, 3_000);
    try testing.expectError(error.NothingToReplyTo, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":3000,"text":"hurry"}
    , 4_000));

    try b.hook(.turn_ended, null, 5_000);
    try testing.expectError(error.Stale, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"go on"}
    , 6_000));
    try testing.expectError(error.EmptyText, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":5000,"text":"  \n"}
    , 6_000));
    try testing.expectEqual(@as(usize, 0), b.rec.texts.items.len);

    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":5000,"text":"go on"}
    , 6_000);
    try testing.expectEqual(@as(usize, 1), b.rec.texts.items.len);
}

test "ControlRoom act: seen and snooze change the group's marks and are written down" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"seen","group":"web-app"}
    , 5_000);
    try testing.expectEqual(@as(?u64, wall + 5_000), (try b.chat.marksOf("web-app")).seen_ms);
    try testing.expectEqual(@as(?u64, 5_000), b.chat.seenRunMs("web-app"));

    try b.act(
        \\{"act":"snooze","group":"web-app"}
    , 6_000);
    try testing.expectEqual(Chat.Marks.Snooze{ .next_event = wall + 6_000 }, (try b.chat.marksOf("web-app")).snooze);

    try b.act(
        \\{"act":"snooze","group":"web-app","until_ms":1700000090000}
    , 7_000);
    try testing.expectEqual(
        Chat.Marks.Snooze{ .until = .{ .at_ms = wall + 7_000, .until_ms = wall + 90_000 } },
        (try b.chat.marksOf("web-app")).snooze,
    );

    try b.act(
        \\{"act":"unsnooze","group":"web-app"}
    , 8_000);
    try testing.expectEqual(Chat.Marks.Snooze.none, (try b.chat.marksOf("web-app")).snooze);

    // Each of the four was handed on to be written, as it stood then.
    try testing.expectEqual(@as(usize, 4), b.rec.persisted.items.len);
    try testing.expectEqual(Chat.Marks.Snooze.none, b.rec.persisted.items[3].snooze);
    try testing.expectEqual(@as(?u64, wall + 5_000), b.rec.persisted.items[3].seen_ms);
    // And none of them touched a terminal.
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom act: a mark on a group that is not there, or a snooze into the past, is refused" {
    var b = try Bench.init();
    defer b.deinit();

    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"seen","group":"nope"}
    , 1_000));
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"snooze","group":"nope"}
    , 1_000));
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"unsnooze","group":"nope"}
    , 1_000));
    try testing.expectError(error.SnoozeInThePast, b.act(
        \\{"act":"snooze","group":"web-app","until_ms":1700000000500}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.persisted.items.len);
}

test "ControlRoom act: a request that is not one is refused before anything is looked at" {
    var b = try Bench.init();
    defer b.deinit();
    const bad = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"act\":\"archive\",\"group\":\"web-app\"}",
        "{\"act\":\"seen\"}",
        "{\"act\":\"approve\",\"terminal\":\"161\",\"since_ms\":1,\"event_ms\":1}",
        "{\"act\":\"approve\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":1}",
        "{\"act\":\"approve\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":-1,\"event_ms\":1}",
        "{\"act\":\"reply\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":1}",
    };
    for (bad) |json| try testing.expectError(error.BadRequest, b.act(json, 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom start: a new group is made by the name that was typed, or refused by name" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"new_group","name":"  billing-2 \n"}
    , 1_000);
    try testing.expect(b.chat.exists("billing-2"));
    // The person made it, and is in it.
    try testing.expectEqual(Chat.user_id, try b.chat.createdBy("billing-2"));

    try testing.expectError(error.GroupExists, b.act(
        \\{"act":"new_group","name":"web-app"}
    , 1_000));
    // Not turned into a name nobody typed.
    for ([_][]const u8{ "", "   ", "Web App", "web_app", "群", "a" ** 49 }) |bad| {
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"act\":\"new_group\",\"name\":\"{s}\"}}", .{bad});
        try testing.expectError(error.BadName, b.act(json, 1_000));
    }
    try testing.expectEqual(@as(usize, 2), b.chat.groups.count());

    b.rec.refuse_with = error.TooManyGroups;
    try testing.expectError(error.TooManyGroups, b.act(
        \\{"act":"new_group","name":"one-more"}
    , 1_000));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"new_group"}
    , 1_000));
}

test "ControlRoom start: a supervisor is started for a group that has none, once" {
    var b = try Bench.init();
    defer b.deinit();
    try b.chat.restoreShell("nightly", "", 0, .none);

    // No such group, and one that is minded: nothing is opened for either.
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"start_supervisor","group":"nope"}
    , 1_000));
    b.rec.steward = term;
    try testing.expectError(error.HasSupervisor, b.act(
        \\{"act":"start_supervisor","group":"web-app"}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.started.items.len);

    // With nothing named, the host is handed nothing to override with.
    b.rec.steward = null;
    try b.act(
        \\{"act":"start_supervisor","group":"nightly"}
    , 1_000);
    try testing.expectEqual(@as(usize, 1), b.rec.started.items.len);
    try testing.expectEqualStrings("", b.rec.started.items[0].role);
    try testing.expectEqualStrings("", b.rec.started.items[0].cwd);
    // Nor a session: left out is the last one, where it can be gone on with.
    try testing.expectEqual(Session.last, b.rec.started.items[0].session);

    // One is on its way (the real host records that as it opens the tab):
    // a second press opens nothing.
    try b.chat.beginStart("nightly", 1_000, 11_000, false);
    try testing.expectError(error.AlreadyStarting, b.act(
        \\{"act":"start_supervisor","group":"nightly","role":"night-lead","cwd":"/work"}
    , 2_000));
    try testing.expectEqual(@as(usize, 1), b.rec.started.items.len);

    // It failed: trying again is allowed, and what was picked is handed on.
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","role":"night-lead","cwd":"/work"}
    , 11_001);
    try testing.expectEqual(@as(usize, 2), b.rec.started.items.len);

    // Which session is the person's to say, and is handed on as said.
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","session":"new"}
    , 11_001);
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","session":"last"}
    , 11_001);
    try testing.expectEqual(Session.new, b.rec.started.items[2].session);
    try testing.expectEqual(Session.last, b.rec.started.items[3].session);
    // A word that is neither starts nothing.
    for ([_][]const u8{
        \\{"act":"start_supervisor","group":"nightly","session":"resume"}
        ,
        \\{"act":"start_supervisor","group":"nightly","session":""}
        ,
        \\{"act":"start_supervisor","group":"nightly","session":true}
        ,
    }) |bad| try testing.expectError(error.BadRequest, b.act(bad, 11_001));
    try testing.expectEqual(@as(usize, 4), b.rec.started.items.len);

    // What the host refuses is the answer, by its own name.
    b.rec.refuse_with = error.NoSuchDirectory;
    try testing.expectError(error.NoSuchDirectory, b.act(
        \\{"act":"start_supervisor","group":"nightly","cwd":"/gone"}
    , 11_002));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"start_supervisor","group":"nightly","role":7}
    , 11_002));
}

test "ControlRoom act: a terminal in no group is marked seen by its own id" {
    var b = try Bench.init();
    defer b.deinit();
    try testing.expectEqual(@as(?u64, null), b.bus.seenOf(term));

    try b.act(
        \\{"act":"seen","terminal":"0x00000000000000a1"}
    , 5_000);
    try testing.expectEqual(@as(?u64, 5_000), b.bus.seenOf(term));
    // Nothing is written down for it, and no key goes anywhere.
    try testing.expectEqual(@as(usize, 0), b.rec.persisted.items.len);
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
    // A group's seen is still a group's.
    try testing.expectEqual(@as(?u64, null), b.chat.seenRunMs("web-app"));

    try testing.expectError(error.UnknownTerminal, b.act(
        \\{"act":"seen","terminal":"0x00000000000000ff"}
    , 6_000));
    // A row is one or the other; both, or a terminal that is not an id, is
    // not a request.
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"seen","group":"web-app","terminal":"0x00000000000000a1"}
    , 6_000));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"seen","terminal":"161"}
    , 6_000));
    try testing.expectEqual(@as(?u64, 5_000), b.bus.seenOf(term));
}
