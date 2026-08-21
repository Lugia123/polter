//! The request surface Poltergeist exposes to agents, and the permission
//! matrix that governs it.
//!
//! An agent never talks to this directly. It speaks MCP to a sidecar
//! process, which speaks this over a local socket. The split matters for
//! trust: the sidecar's identity comes from `GHOSTTY_SURFACE_ID`, injected
//! by the host into the pty's environment, so an agent cannot claim to be a
//! terminal it is not.
//!
//! This file is pure -- it decides what is permitted, not how to do it. The
//! doing lives in the app, which has the surfaces. Keeping the matrix here
//! means it can be tested exhaustively without a terminal, a socket, or an
//! agent. See `docs/poltergeist/mcp.md`.

const std = @import("std");

const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");

const log = std.log.scoped(.poltergeist);

pub const Method = enum {
    /// Which terminal am I, what is my role, what work mode am I under.
    me,

    /// Every terminal that is open, with its quiescence duration and
    /// duty state. Durations and bookkeeping only -- never screen contents.
    terminal_list,

    /// What has happened that the supervisor has not been shown yet.
    ///
    /// Reading consumes: the same thing is not handed over twice. This is
    /// the supervisor asking of its own accord, so unlike the scheduled
    /// hand-over it is never held back -- choosing to look is not an
    /// interruption. Use it after finishing something, rather than waiting
    /// to be told.
    notices,

    /// Who is in a group, so a reader can see who is there rather than
    /// inferring it from who has spoken.
    group_members,

    /// Say what a group is for. The supervisor's own note, for reading
    /// back hours later when it no longer remembers why it made this one.
    group_set_brief,

    /// Ask for the person to be told something.
    ///
    /// The program never decides that a human is needed -- it cannot read
    /// a screen and would not know an authorisation prompt from a spinner.
    /// You looked; you say so. Whether it actually reaches them depends on
    /// what they have configured and, for scheduling questions, on the
    /// hour.
    notify_user,

    /// What last night's arrangement was, as written down before the
    /// restart.
    ///
    /// Read-only, and nothing acts on it. Which terminal on screen now is
    /// which one from the notes is a judgement, and it is yours -- the
    /// program guessing would attach one terminal's supervision to another
    /// and look fine doing it.
    session_recall,

    /// Read what is on another terminal's screen.
    terminal_read,

    /// Type into another terminal, as if the user had.
    terminal_send,

    /// Mark a terminal as done for the day.
    clock_out,

    /// Put a terminal back on duty.
    clock_in,

    /// Ask what work mode a terminal is under.
    get_work_mode,

    /// Change how long this terminal must be still before the supervisor
    /// hears about it.
    set_quiescence_threshold,

    /// Put a terminal under supervision, or take it out again.
    ///
    /// The supervisor's, because arranging who is minded is the same kind
    /// of decision as arranging who talks to whom. Note what it grants:
    /// a terminal under supervision can be read and typed into, so this is
    /// the tool that decides reach.
    set_watch,

    /// Change what a terminal's work mode asks of it.
    ///
    /// Scheduling, which is the supervisor's job. It may put a terminal
    /// into an infinite mode and move it between them -- but an infinite
    /// mode the *user* set is a standing instruction, and lifting that is
    /// refused however the request is routed.
    set_work_mode,

    /// Read one of Poltergeist's skills: the text describing how to do this
    /// job. Any terminal may read one; they are instructions, not reach.
    skill_read,

    /// Make a group, or take one away. The supervisor's alone: it decides
    /// who talks to whom.
    group_create,
    group_destroy,

    /// Put a terminal in a group or take it out, choosing what it sees of
    /// what was said before. The supervisor's alone.
    group_add,
    group_remove,

    /// Replace a stretch of a group's history with a summary. The
    /// supervisor's alone -- it is the one that can judge what a
    /// conversation amounted to.
    group_compact,

    /// Which groups am I in.
    group_list,

    /// Say something to a group, or read what has been said.
    group_post,
    group_read,
};

pub const Request = union(Method) {
    me,
    terminal_list,
    notices,
    group_members: struct { group: []const u8 },
    group_set_brief: struct { group: []const u8, text: []const u8 },

    notify_user: struct {
        /// `scheduling` or `authorisation`. The second is never held back
        /// for quiet hours, because nobody may answer it for them.
        reason: []const u8,
        title: []const u8,
        body: []const u8 = "",
        id: Bus.Id = 0,
    },

    session_recall,
    terminal_read: struct { id: Bus.Id, lines: u16 = 0 },
    terminal_send: struct { id: Bus.Id, text: []const u8, submit: bool = true },
    clock_out: struct { id: Bus.Id, reason: []const u8 = "" },
    clock_in: struct { id: Bus.Id },
    get_work_mode: struct { id: Bus.Id },
    set_quiescence_threshold: struct { id: Bus.Id, ms: u64 },
    set_watch: struct { id: Bus.Id, watch: bool },
    set_work_mode: struct { id: Bus.Id, mode: []const u8 },
    skill_read: struct { name: []const u8 },

    group_create: struct { group: []const u8 },
    group_destroy: struct { group: []const u8 },
    group_add: struct { group: []const u8, id: Bus.Id, history: History = .none },
    group_remove: struct { group: []const u8, id: Bus.Id },
    group_compact: struct { group: []const u8, through: u64, summary: []const u8 },
    group_list,
    group_post: struct { group: []const u8, text: []const u8 },
    group_read: struct { group: []const u8, since: u64 = 0 },
};

/// How much text one `group_read` reply may carry.
///
/// The protocol is one JSON object per line, and both readers take a line
/// into a fixed buffer -- so a reply larger than that buffer is not a slow
/// reply, it is `StreamTooLong` and a connection that never recovers,
/// because the next attempt asks for the same range again.
///
/// A group holds up to a thousand messages of up to eight kilobytes each,
/// so an unbounded reply had eight megabytes of headroom over a sixty-four
/// kilobyte buffer. It took a few days of real use to get there.
///
/// The budget is over the *raw* text. JSON escaping inflates it, and worst
/// of all for CJK: `std.json` writes a three-byte character as a six-byte
/// `\uXXXX` escape, so Chinese doubles. The figure below leaves room for
/// that doubling inside the smaller of the two read buffers.
pub const read_budget_bytes: usize = 96 * 1024;

/// Keep the oldest messages that fit the budget.
///
/// Oldest first, not newest: the caller polls with a cursor, so handing
/// back the front of the range lets it advance and ask again. Nothing is
/// lost, it only arrives in instalments. Handing back the newest instead
/// would strand everything before them behind a cursor that had already
/// moved past.
pub fn capMessages(lines: []const ChatLine) []const ChatLine {
    var used: usize = 0;
    for (lines, 0..) |line, i| {
        used += line.text.len + line.author.len;
        if (used > read_budget_bytes) {
            // At least one, however big it is: returning none would have
            // the caller poll forever without its cursor ever moving.
            return lines[0..@max(i, 1)];
        }
    }
    return lines;
}

pub const History = @import("Chat.zig").History;

pub const Error = error{
    /// The caller's role does not permit this method.
    NotPermitted,

    /// No terminal by that id.
    UnknownTerminal,

    /// The terminal's work mode forbids clocking off.
    WorkModeForbids,

    /// A terminal may not act on itself through this surface.
    SelfTarget,

    /// Another supervisor is minding that terminal.
    NotYours,
};

/// Whether a method needs the caller to be the supervisor.
///
/// The shape is a star, not a mesh: the supervisor may reach every watched
/// terminal, and a watched terminal may reach nobody. Peer-to-peer control
/// would mean an agent could be steered by another agent that the user
/// never put in charge of it, and the terminal on the receiving end cannot
/// tell the difference between that and the user typing.
pub fn requiresSupervisor(method: Method) bool {
    return switch (method) {
        // Every terminal may ask about itself.
        .me => false,

        .terminal_list,
        .notices,
        .terminal_read,
        .terminal_send,
        .clock_out,
        .clock_in,
        .get_work_mode,
        .set_quiescence_threshold,
        .set_watch,
        .set_work_mode,
        .group_set_brief,
        .session_recall,
        .notify_user,
        => true,

        // Skills are instructions, not reach. A watched terminal reading
        // how supervision works learns nothing it could not be told, and
        // refusing would mean an agent cannot find out why it was nudged.
        .skill_read => false,

        // Who talks to whom is the supervisor's to arrange, the same way
        // who is watched is. A terminal that could make its own groups and
        // pull others into them would be building a structure the user
        // never set up.
        .group_create,
        .group_destroy,
        .group_add,
        .group_remove,
        .group_compact,
        => true,

        // Talking inside a group it was already put in, though, is not
        // steering. The star topology exists so no agent can put text in
        // another's input box uninvited; a message the recipient has to go
        // and fetch is the opposite of that, and a team that cannot talk to
        // each other is not a team.
        .group_list,
        .group_post,
        .group_read,
        .group_members,
        => false,
    };
}

/// Whether a method targets another terminal, and so must be checked
/// against the bus for existence.
pub fn targetsTerminal(method: Method) bool {
    return switch (method) {
        .me,
        .terminal_list,
        .notices,
        .session_recall,
        .notify_user,
        .skill_read,
        .group_create,
        .group_destroy,
        .group_compact,
        .group_list,
        .group_post,
        .group_read,
        .group_members,
        .group_set_brief,
        => false,

        // Both name another terminal, so both go through the self-target
        // check: a supervisor arranging its own supervision is a knot, not
        // a feature.
        .set_watch,
        .set_work_mode,
        => true,

        // These name a terminal to put in or take out of a group. Checked
        // for existence so a typo fails rather than vanishing.
        .group_add,
        .group_remove,
        .terminal_read,
        .terminal_send,
        .clock_out,
        .clock_in,
        .get_work_mode,
        .set_quiescence_threshold,
        => true,
    };
}

/// The target terminal, if this request has one.
pub fn target(req: Request) ?Bus.Id {
    return switch (req) {
        .me,
        .terminal_list,
        .notices,
        .skill_read,
        .group_create,
        .group_destroy,
        .group_compact,
        .group_list,
        .group_post,
        .group_read,
        .group_members,
        .group_set_brief,
        .session_recall,
        .notify_user,
        => null,

        inline .group_add, .group_remove => |v| v.id,
        inline else => |v| v.id,
    };
}

/// Decide whether `caller` may make this request.
///
/// Note what is *not* here: there is no way to change a work mode. That is
/// deliberate and is what makes the ban on clocking off an infinite-mode
/// terminal worth anything -- a supervisor that could switch the mode would
/// simply switch it and then clock off. Work mode is the user's, set from
/// the terminal itself, and this surface can only read it.
///
/// There is also no tool for answering a permission prompt on another
/// agent's behalf, and there will not be one. See `docs/poltergeist/`.
pub fn authorize(bus: *const Bus, caller: Bus.Id, req: Request) Error!void {
    const method: Method = req;

    if (requiresSupervisor(method) and !bus.isSupervisor(caller)) {
        return error.NotPermitted;
    }

    if (target(req)) |id| {
        // The supervisor reaching into itself is always a mistake, and an
        // agent typing into its own terminal through this surface would be
        // a loop with no natural end.
        if (id == caller) return error.SelfTarget;

        // Being *a* supervisor is not being *this terminal's* supervisor.
        // With several of them in a window, reach follows who is minding
        // what: otherwise one supervisor could read and type into another
        // one's workers, which is the thing the star topology exists to
        // prevent -- it just has more than one centre now.
        //
        // `set_watch` is how a terminal gets an owner, so it is the one
        // thing that cannot require having one already.
        if (method != .set_watch) {
            // A terminal the bus has never heard of is a different mistake
            // from one somebody else is minding, and saying so is the
            // difference between "check your id" and "that one is not
            // yours".
            if (bus.get(id) == null) return error.UnknownTerminal;
            if (!bus.minds(caller, id)) return error.NotYours;
        }

        // Everything else here acts on a terminal already under
        // supervision -- except the tool that *puts* one there. Requiring
        // `set_watch`'s target to be known already made it refuse every
        // terminal it was for, which is all of them: a terminal you are
        // about to start watching is by definition not being watched.
        //
        // Whether the id is a terminal at all is still checked, by the
        // host, which is the side that knows.

    }

    // Refuse a clock-out the bus would refuse anyway, so the sidecar gets
    // the real reason instead of a generic failure. The bus is still the
    // authority; this only makes the answer honest earlier.
    if (req == .clock_out) {
        const e = bus.get(req.clock_out.id).?;
        if (e.work_mode.forbidsClockOff()) return error.WorkModeForbids;
    }
}

/// A stable string for each error, for the sidecar to hand back to the
/// agent. Agents read these, so they say what to do about it.
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NotPermitted => "not permitted: only a supervisor may do this",
        error.UnknownTerminal => "no terminal with that id",
        error.WorkModeForbids => "this terminal runs in an infinite work mode and cannot clock out; only the user can change that",
        error.SelfTarget => "a terminal cannot target itself",
        error.NotYours => "another supervisor is minding that terminal; " ++
            "watch it yourself first, or leave it to them",
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const boss: Bus.Id = 0x1111;
const worker: Bus.Id = 0x2222;
const other: Bus.Id = 0x3333;

fn testBus(alloc: std.mem.Allocator) !Bus {
    var b: Bus = .init(alloc, .{});
    errdefer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    return b;
}

test "only what reaches another terminal needs the supervisor" {
    // Two lines, not one. Arranging who talks to whom is the supervisor's,
    // the same way arranging who is watched is. Talking inside a group it
    // was already put in is not: the recipient has to come and fetch it.
    for (std.enums.values(Method)) |m| {
        const open = switch (m) {
            .me,
            .skill_read,
            .group_list,
            .group_post,
            .group_read,
            .group_members,
            => true,

            // Writing what a group is for is arranging, not talking.
            // Reading last night's arrangement, likewise.
            .group_set_brief,
            .session_recall,
            .notify_user,

            .terminal_list,
            .notices,
            .terminal_read,
            .terminal_send,
            .clock_out,
            .clock_in,
            .get_work_mode,
            .set_quiescence_threshold,
            .set_watch,
            .set_work_mode,
            .group_create,
            .group_destroy,
            .group_add,
            .group_remove,
            .group_compact,
            => false,
        };
        try testing.expectEqual(!open, requiresSupervisor(m));
    }
}

test "a watched terminal can talk in a group but cannot arrange one" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    // Talking: allowed.
    const posted = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .group_post = .{ .group = "build", .text = "build is green" },
    });
    try testing.expect(posted == .ok);
    try testing.expectEqualStrings("build is green", fake.posted.?.text);
    try testing.expectEqualStrings("build", fake.posted.?.group);

    // Making a group, or pulling somebody into one: refused.
    for ([_]Request{
        .{ .group_create = .{ .group = "mine" } },
        .{ .group_add = .{ .group = "build", .id = boss } },
        .{ .group_remove = .{ .group = "build", .id = boss } },
        .{ .group_compact = .{ .group = "build", .through = 1, .summary = "x" } },
        .{ .group_destroy = .{ .group = "build" } },
    }) |req| {
        const res = try dispatch(testing.allocator, &b, fake.host(), worker, req);
        try testing.expectEqualStrings("NotPermitted", res.failed.code);
    }
}

test "the supervisor chooses what a terminal it adds can see" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    _ = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .group_add = .{ .group = "build", .id = worker, .history = .none },
    });
    try testing.expectEqual(History.none, fake.added.?.history);

    _ = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .group_add = .{ .group = "build", .id = worker, .history = .all },
    });
    try testing.expectEqual(History.all, fake.added.?.history);
}

test "adding a terminal that does not exist is refused" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .group_add = .{ .group = "build", .id = 0xdead },
    });
    try testing.expectEqualStrings("UnknownTerminal", res.failed.code);
}

test "compacting carries the summary the supervisor wrote" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    _ = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .group_compact = .{
            .group = "build",
            .through = 42,
            .summary = "they argued about the build",
        },
    });

    try testing.expectEqual(@as(u64, 42), fake.compacted.?.through);
    try testing.expectEqualStrings("they argued about the build", fake.compacted.?.summary);
    try testing.expectEqual(boss, fake.compacted.?.by);
}

test "what the chat log refuses comes back as something to act on" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .group_post = .{ .group = "nope", .text = "hello" },
    });
    try testing.expectEqualStrings("NoSuchGroup", res.failed.code);
    try testing.expect(res.failed.message.len > 0);
}

test "group_list names the groups a terminal is in" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .group_list);
    defer {
        for (res.groups) |g| {
            testing.allocator.free(g.name);
            if (g.brief.len > 0) testing.allocator.free(g.brief);
        }
        testing.allocator.free(res.groups);
    }
    try testing.expectEqual(@as(usize, 1), res.groups.len);
    try testing.expectEqualStrings("build", res.groups[0].name);
}

test "group_read asks for the group it was given" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .group_read = .{ .group = "research", .since = 7 },
    });
    defer {
        for (res.messages) |m| {
            testing.allocator.free(m.text);
            testing.allocator.free(m.author);
        }
        testing.allocator.free(res.messages);
    }
    try testing.expectEqualStrings("research", fake.read_group.?);
    try testing.expectEqual(@as(u64, 8), res.messages[0].seq);
}

test "a watched terminal may only ask about itself" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, worker, .me);

    try testing.expectError(error.NotPermitted, authorize(&b, worker, .terminal_list));
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .{
        .terminal_read = .{ .id = boss },
    }));
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .{
        .terminal_send = .{ .id = boss, .text = "hello" },
    }));
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .{
        .clock_out = .{ .id = worker },
    }));
}

test "the supervisor may reach a watched terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, boss, .terminal_list);
    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });
    try authorize(&b, boss, .{ .terminal_send = .{ .id = worker, .text = "继续" } });
    try authorize(&b, boss, .{ .clock_out = .{ .id = worker } });
    try authorize(&b, boss, .{ .get_work_mode = .{ .id = worker } });
}

test "a terminal cannot target itself" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(error.SelfTarget, authorize(&b, boss, .{
        .terminal_send = .{ .id = boss, .text = "loop" },
    }));
    try testing.expectError(error.SelfTarget, authorize(&b, boss, .{
        .terminal_read = .{ .id = boss },
    }));
}

test "an unknown target is rejected" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(error.UnknownTerminal, authorize(&b, boss, .{
        .terminal_read = .{ .id = 0xdead },
    }));
}

test "with no supervisor named, nothing but me is permitted" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.watch(worker, boss);

    try authorize(&b, worker, .me);
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .terminal_list));
}

test "clock_out is refused for an infinite work mode" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.setWorkMode(worker, .infinite_directed, .user);
    try testing.expectError(error.WorkModeForbids, authorize(&b, boss, .{
        .clock_out = .{ .id = worker },
    }));

    // Clocking a terminal back in is never refused: coming back to work is
    // not the dangerous direction.
    try authorize(&b, boss, .{ .clock_in = .{ .id = worker } });
}

test "a work mode may be arranged here, but a user's standing one may not be lifted" {
    // This surface used to have no way to change a work mode at all: the ban
    // on clocking off an infinite-mode terminal is only worth something if
    // the mode itself cannot be swapped out from under it.
    //
    // The supervisor arranges work now, so the rule moved rather than went
    // away. The bus refuses to lift an infinite mode the *user* set -- and
    // that refusal is what this test guards, because it is the only thing
    // standing between "keep going" and an agent deciding otherwise.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    // The supervisor may put a terminal into an infinite mode.
    try authorize(&b, boss, .{ .set_work_mode = .{
        .id = worker,
        .mode = "infinite_directed",
    } });

    // But once the user has said it, only the user unsays it.
    try b.setWorkMode(worker, .infinite_directed, .user);
    try testing.expectError(
        error.NotPermitted,
        b.setWorkMode(worker, .clock_off, .supervisor),
    );
    try testing.expectError(
        error.WorkModeForbids,
        b.clockOff(worker, .supervisor),
    );
}

test "there is no tool for answering another agent's permission prompt" {
    // `terminal_send` is a general text primitive and that is all there is.
    // A dedicated approve/deny tool would make it one step to hand away
    // another agent's safety model, so there is none.
    for (std.enums.values(Method)) |m| {
        const name = @tagName(m);
        try testing.expect(std.mem.indexOf(u8, name, "approve") == null);
        try testing.expect(std.mem.indexOf(u8, name, "confirm") == null);
        try testing.expect(std.mem.indexOf(u8, name, "permission") == null);
    }
}

test "target reports the terminal a request acts on" {
    try testing.expect(target(.me) == null);
    try testing.expect(target(.terminal_list) == null);
    try testing.expectEqual(worker, target(.{ .terminal_read = .{ .id = worker } }).?);
    try testing.expectEqual(worker, target(.{ .clock_out = .{ .id = worker } }).?);
    try testing.expectEqual(
        worker,
        target(.{ .set_quiescence_threshold = .{ .id = worker, .ms = 1000 } }).?,
    );
}

test "targetsTerminal agrees with target" {
    try testing.expect(!targetsTerminal(.me));
    try testing.expect(!targetsTerminal(.terminal_list));
    try testing.expect(targetsTerminal(.terminal_read));
    try testing.expect(targetsTerminal(.set_quiescence_threshold));
}

test "every error has a message that says what to do" {
    const errs = [_]Error{
        error.NotPermitted,
        error.UnknownTerminal,
        error.WorkModeForbids,
        error.SelfTarget,
    };
    for (errs) |e| {
        const msg = errorMessage(e);
        try testing.expect(msg.len > 0);
        // Lowercase start, no trailing period: these are appended to the
        // sidecar's own framing rather than read as sentences.
        try testing.expect(msg[0] >= 'a' and msg[0] <= 'z');
        try testing.expect(msg[msg.len - 1] != '.');
    }
}

test "letting a terminal go gives up reaching it" {
    // This used to say the opposite: unwatching stopped the reports but
    // left the supervisor able to read the terminal, because with one
    // supervisor reach was global and watching was only about noise.
    //
    // With several, reach follows who is minding what -- so letting a
    // terminal go is giving it up, and that is the point. Otherwise a
    // supervisor could unwatch a terminal to stop hearing about it and
    // still type into it, which is not a coherent thing to offer.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });

    b.unwatch(worker);
    try testing.expectError(error.NotYours, authorize(&b, boss, .{
        .terminal_read = .{ .id = worker },
    }));

    // And it still cannot act on anyone.
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .terminal_list));
}

test "a supervisor stood down immediately loses its reach" {
    // Naming a second supervisor used to stand the first one down, and
    // this test proved the reach went with it. Supervisors are peers now,
    // so standing one down is its own act.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });

    b.removeSupervisor(boss);
    try testing.expectError(error.NotPermitted, authorize(&b, boss, .{
        .terminal_read = .{ .id = worker },
    }));
}

test "one supervisor cannot reach another's terminals" {
    // The property that makes several supervisors safe. Without it, naming
    // a second supervisor would hand it every worker in the window --
    // including ones the user put under somebody else.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.addSupervisor(other);

    // `other` is a supervisor, but it is not minding `worker`.
    try testing.expectError(error.NotYours, authorize(&b, other, .{
        .terminal_read = .{ .id = worker },
    }));
    try testing.expectError(error.NotYours, authorize(&b, other, .{
        .terminal_send = .{ .id = worker, .text = "hello" },
    }));

    // And the one that is minding it still can.
    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });
}

test "a terminal already minded is not quietly taken over" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.addSupervisor(other);
    try testing.expectError(error.AlreadyWatched, b.watch(worker, other));

    // Still the first one's.
    try testing.expect(b.minds(boss, worker));
}

// -- dispatch ---------------------------------------------------------------

const wire = @import("wire.zig");

/// Most screen text one reply may carry, comfortably under what the sidecar
/// will read back.
const max_text_bytes = 128 * 1024;

/// One message as it goes out on the wire.
pub const ChatLine = struct {
    seq: u64,
    from: Bus.Id,

    /// What the terminal that said this was called at the time, which is
    /// the same string its tab is showing. Carried so that a reader can
    /// tell which window a message came from; an id cannot be matched
    /// against anything on screen.
    author: []const u8,

    /// Unix milliseconds, so this can be shown as a time of day. The log
    /// itself runs on a monotonic clock -- right for measuring stillness,
    /// useless for saying when somebody spoke -- and the host converts.
    at_ms: i64,

    /// True when this stands in for messages the supervisor compacted away.
    summary: bool,

    text: []const u8,
};

/// One member of a group.
pub const ChatMember = struct {
    id: Bus.Id,
    title: []const u8,
};

/// One group as it appears in a listing.
///
/// `brief` is empty for the watched terminals -- not because the text is
/// secret, but because it is a memo, and a note you might have to justify
/// to your peers stops being worth writing. The supervisor wrote it; the
/// person at the keyboard owns the machine. This is the first place a
/// reply depends on who asked; the reasoning is the same as
/// `history: none`, that visibility is reckoned per person rather than
/// per datum.
pub const ChatGroupInfo = struct {
    name: []const u8,
    brief: []const u8,
};

/// What the app must supply for a request to be carried out.
///
/// An interface rather than a direct dependency on `App` so the dispatch
/// rules can be tested against a fake. It is deliberately narrow: reading a
/// screen, typing into one, and two numbers. Anything wider would invite
/// the tool surface to grow capabilities that were never argued for.
/// A terminal and the two things about it that can be put back.
///
/// Where it was working and what its tab said. Deliberately not "what was
/// running in it": that may be an agent whose session can be resumed, or it
/// may be a shell with a half-finished build in it, and only the first of
/// those can be restored by a command. The directory and the name are true
/// of both.
pub const Place = struct {
    id: Bus.Id,
    cwd: []const u8 = "",
    title: []const u8 = "",
};

pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The visible screen, or the last `lines` rows when non-zero.
        /// Returned memory belongs to the caller's allocator.
        readTerminal: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
            lines: u16,
        ) anyerror![]const u8,

        /// Type text into a terminal as if the user had.
        sendText: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            text: []const u8,
            submit: bool,
        ) anyerror!void,

        /// How long that terminal's screen has been unchanged.
        quietMs: *const fn (ctx: *anyopaque, id: Bus.Id) u64,

        /// Start or stop sampling a terminal's screen.
        ///
        /// Separate from the bus entry because they are separate facts: the
        /// entry says a terminal is meant to be watched, and this makes
        /// something actually look at it. Marked without this, a terminal
        /// reports nothing and looks broken rather than unwatched.
        setWatching: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            watching: bool,
        ) anyerror!void,

        /// Every terminal the app has open, minded or not.
        ///
        /// The bus only knows terminals somebody put under watch, and
        /// after a restart that is none of them -- which is exactly when
        /// the supervisor needs to see what is on screen in order to match
        /// it against last night's notes. Asking the host instead is the
        /// difference between a restore procedure that can be carried out
        /// and one that can only be written down.
        ///
        /// Where and what it is called, and nothing else: no screen
        /// contents, and no measurement of terminals nobody asked to be
        /// measured. Returned memory belongs to the caller's allocator.
        openTerminals: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) anyerror![]const Place,

        /// Everything the supervisor has not been shown, cleared as it is
        /// read. Empty when there is nothing waiting. Returned memory
        /// belongs to the caller's allocator.
        ///
        /// Goes through the host rather than straight to the bus because
        /// the clock does: the bus is given time, it does not keep it.
        drainNotices: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            to: Bus.Id,
        ) anyerror![]const u8,

        /// Change how long it must be still before it is reported.
        setThreshold: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            ms: u64,
        ) anyerror!void,

        /// The prose of one skill. Returned memory belongs to the caller's
        /// allocator.
        readSkill: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            name: []const u8,
        ) anyerror![]const u8,

        chatCreate: *const fn (ctx: *anyopaque, group: []const u8, by: Bus.Id) anyerror!void,
        chatDestroy: *const fn (ctx: *anyopaque, group: []const u8) anyerror!void,

        chatAdd: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            id: Bus.Id,
            history: History,
        ) anyerror!void,

        chatRemove: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            id: Bus.Id,
        ) anyerror!void,

        chatCompact: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            through: u64,
            summary: []const u8,
            by: Bus.Id,
        ) anyerror!void,

        chatPost: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            from: Bus.Id,
            text: []const u8,
        ) anyerror!void,

        /// Groups `id` is in. The slice and the names inside it must belong
        /// to `alloc`.
        /// Who is in a group, with what each one is currently called.
        /// Returned memory belongs to the caller's allocator.
        /// Who made a group, so the tools that rearrange one can refuse a
        /// supervisor that did not.
        chatOwner: *const fn (ctx: *anyopaque, group: []const u8) anyerror!Bus.Id,

        chatMembers: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
        ) anyerror![]const ChatMember,

        /// Say what a group is for. Replaces whatever was there.
        chatSetBrief: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            text: []const u8,
        ) anyerror!void,

        /// The groups this terminal is in.
        ///
        /// `want_brief` decides whether each group's note comes along.
        /// Passed down rather than filtered afterwards: a note that was
        /// never fetched cannot be leaked by a later mistake, and there is
        /// nothing to free.
        ///
        /// Returned memory belongs to the caller's allocator.
        /// Tell the person something, through whatever they configured.
        ///
        /// Returns what came of it, as a sentence to hand back -- the
        /// supervisor has to know whether the message actually went
        /// anywhere, because if it did not, waiting for an answer is
        /// waiting for nothing.
        notifyUser: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            reason: []const u8,
            title: []const u8,
            body: []const u8,
            id: Bus.Id,
        ) anyerror![]const u8,

        /// Last night's arrangement, as JSON. Empty when there is none.
        ///
        /// Handed over as text rather than parsed into types: the program
        /// does nothing with it, and every field it would parse is one
        /// more thing to keep in step for no reader's benefit.
        sessionRecall: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) anyerror![]const u8,

        chatGroupInfo: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
            want_brief: bool,
        ) anyerror![]ChatGroupInfo,

        chatGroups: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
        ) anyerror![]const []const u8,

        /// Messages `id` has not seen in `group`, above `since`.
        ///
        /// Both the slice and the text inside it must belong to `alloc`.
        /// Borrowing from the log would not survive: the reply is written
        /// by the connection thread after the app thread has moved on, and
        /// the log trims itself as it grows.
        chatRead: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
            id: Bus.Id,
            since: u64,
        ) anyerror![]const ChatLine,
    };

    fn readTerminal(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
        lines: u16,
    ) anyerror![]const u8 {
        return self.vtable.readTerminal(self.ctx, alloc, id, lines);
    }

    fn sendText(self: Host, id: Bus.Id, text: []const u8, submit: bool) anyerror!void {
        return self.vtable.sendText(self.ctx, id, text, submit);
    }

    fn quietMs(self: Host, id: Bus.Id) u64 {
        return self.vtable.quietMs(self.ctx, id);
    }

    fn openTerminals(self: Host, alloc: std.mem.Allocator) anyerror![]const Place {
        return self.vtable.openTerminals(self.ctx, alloc);
    }

    fn setWatching(self: Host, id: Bus.Id, watching: bool) anyerror!void {
        return self.vtable.setWatching(self.ctx, id, watching);
    }

    fn drainNotices(self: Host, alloc: std.mem.Allocator, to: Bus.Id) anyerror![]const u8 {
        return self.vtable.drainNotices(self.ctx, alloc, to);
    }

    fn notifyUser(
        self: Host,
        alloc: std.mem.Allocator,
        reason: []const u8,
        title: []const u8,
        body: []const u8,
        id: Bus.Id,
    ) anyerror![]const u8 {
        return self.vtable.notifyUser(self.ctx, alloc, reason, title, body, id);
    }

    fn sessionRecall(self: Host, alloc: std.mem.Allocator) anyerror![]const u8 {
        return self.vtable.sessionRecall(self.ctx, alloc);
    }

    fn chatSetBrief(self: Host, group: []const u8, text: []const u8) anyerror!void {
        return self.vtable.chatSetBrief(self.ctx, group, text);
    }

    fn chatGroupInfo(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
        want_brief: bool,
    ) anyerror![]ChatGroupInfo {
        return self.vtable.chatGroupInfo(self.ctx, alloc, id, want_brief);
    }

    fn chatOwner(self: Host, group: []const u8) anyerror!Bus.Id {
        return self.vtable.chatOwner(self.ctx, group);
    }

    /// Refuse a supervisor rearranging a group that is not its own.
    ///
    /// A group nobody can be found for is left alone rather than refused:
    /// the group tools already answer `NoSuchGroup` where that matters,
    /// and turning a lookup failure into a permission failure would say
    /// the wrong thing.
    fn ownsGroup(self: Host, group: []const u8, caller: Bus.Id) bool {
        const owner = self.chatOwner(group) catch return true;
        return owner == caller;
    }

    fn chatMembers(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
    ) anyerror![]const ChatMember {
        return self.vtable.chatMembers(self.ctx, alloc, group);
    }

    fn setThreshold(self: Host, id: Bus.Id, ms: u64) anyerror!void {
        return self.vtable.setThreshold(self.ctx, id, ms);
    }

    fn readSkill(
        self: Host,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) anyerror![]const u8 {
        return self.vtable.readSkill(self.ctx, alloc, name);
    }

    fn chatCreate(self: Host, group: []const u8, by: Bus.Id) anyerror!void {
        return self.vtable.chatCreate(self.ctx, group, by);
    }

    fn chatDestroy(self: Host, group: []const u8) anyerror!void {
        return self.vtable.chatDestroy(self.ctx, group);
    }

    fn chatAdd(
        self: Host,
        group: []const u8,
        id: Bus.Id,
        history: History,
    ) anyerror!void {
        return self.vtable.chatAdd(self.ctx, group, id, history);
    }

    fn chatRemove(self: Host, group: []const u8, id: Bus.Id) anyerror!void {
        return self.vtable.chatRemove(self.ctx, group, id);
    }

    fn chatCompact(
        self: Host,
        group: []const u8,
        through: u64,
        summary: []const u8,
        by: Bus.Id,
    ) anyerror!void {
        return self.vtable.chatCompact(self.ctx, group, through, summary, by);
    }

    fn chatPost(
        self: Host,
        group: []const u8,
        from: Bus.Id,
        text: []const u8,
    ) anyerror!void {
        return self.vtable.chatPost(self.ctx, group, from, text);
    }

    fn chatGroups(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
    ) anyerror![]const []const u8 {
        return self.vtable.chatGroups(self.ctx, alloc, id);
    }

    fn chatRead(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
        id: Bus.Id,
        since: u64,
    ) anyerror![]const ChatLine {
        return self.vtable.chatRead(self.ctx, alloc, group, id, since);
    }
};

/// Carry out one request on behalf of `caller`.
///
/// Authorization happens first and is never skipped: every path out of this
/// function that touches the host has been through `authorize`.
///
/// Anything the host itself refuses comes back as a failure response rather
/// than an error, because the agent on the other end needs to be told what
/// happened -- a silent failure would have it waiting on something that is
/// never going to occur.
pub fn dispatch(
    alloc: std.mem.Allocator,
    bus: *Bus,
    host: Host,
    caller: Bus.Id,
    req: Request,
) std.mem.Allocator.Error!wire.Response {
    authorize(bus, caller, req) catch |err| return failure(err);

    switch (req) {
        .me => return .{ .me = describe(bus, host, caller) },

        .terminal_list => {
            var list: std.ArrayListUnmanaged(wire.TerminalInfo) = .empty;
            defer list.deinit(alloc);

            // Every terminal on screen, not only the ones the bus knows.
            // After a restart the bus knows none of them, and a list that
            // is empty precisely when the supervisor needs it is not a
            // list. Falling back to the bus keeps the tool working for a
            // host that cannot enumerate.
            if (host.openTerminals(alloc)) |places| {
                // The array is ours to release; the strings inside it are
                // not. They are handed on into the response and outlive
                // this list, so only the slice is freed here.
                defer alloc.free(places);

                for (places) |place| {
                    var info = describe(bus, host, place.id);
                    info.cwd = place.cwd;
                    info.title = place.title;
                    try list.append(alloc, info);
                }
            } else |err| {
                log.warn("poltergeist: could not list terminals err={}", .{err});

                var it = bus.entries.iterator();
                while (it.next()) |kv| {
                    try list.append(alloc, describe(bus, host, kv.key_ptr.*));
                }
            }

            // Sorted so that repeated calls read the same way; a hash map's
            // order is not stable and an agent comparing two listings would
            // see phantom movement.
            const owned = try list.toOwnedSlice(alloc);
            std.mem.sort(wire.TerminalInfo, owned, {}, lessById);
            return .{ .terminals = owned };
        },

        .notices => {
            // Empty is a normal answer, and a common one. It is not an
            // error and it is not silence -- the supervisor asked, and the
            // truthful reply is that nothing is waiting.
            const line = host.drainNotices(alloc, caller) catch
                return hostFailure("ReadFailed", "could not read the notices");
            return .{ .text = line };
        },

        .notify_user => |p| {
            const said = host.notifyUser(alloc, p.reason, p.title, p.body, p.id) catch
                return hostFailure("NotifyFailed", "could not attempt to notify");
            return .{ .text = said };
        },

        .session_recall => {
            const text = host.sessionRecall(alloc) catch
                return hostFailure("ReadFailed", "could not read last night's notes");
            return .{ .text = text };
        },

        .group_set_brief => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatSetBrief(p.group, p.text) catch
                return hostFailure("NoSuchGroup", "no group by that name");
            return .ok;
        },

        .group_members => |p| {
            const members = host.chatMembers(alloc, p.group) catch
                return hostFailure("NoSuchGroup", "no group by that name");
            return .{ .members = members };
        },

        .terminal_read => |p| {
            // Accepted in the wire format for forward compatibility, but
            // refused rather than ignored: an agent that asked for
            // scrollback and silently got the visible screen would reason
            // about rows it never saw.
            if (p.lines != 0) return hostFailure(
                "NotImplemented",
                "reading scrollback is not available; omit `lines` for the visible screen",
            );

            const text = host.readTerminal(alloc, p.id, 0) catch
                return hostFailure("ReadFailed", "could not read that terminal");

            // Bounded so one reply cannot exceed what the sidecar will
            // read. A truncated screen with a note beats a desynchronised
            // connection.
            if (text.len > max_text_bytes) {
                defer alloc.free(text);
                return .{ .text = try std.fmt.allocPrint(
                    alloc,
                    "[truncated to the last {d} bytes]\n{s}",
                    .{ max_text_bytes, text[text.len - max_text_bytes ..] },
                ) };
            }

            return .{ .text = text };
        },

        .terminal_send => |p| {
            host.sendText(p.id, p.text, p.submit) catch
                return hostFailure("SendFailed", "could not type into that terminal");
            return .ok;
        },

        .clock_out => |p| {
            bus.clockOff(p.id, .supervisor) catch |err| return switch (err) {
                error.WorkModeForbids => failure(error.WorkModeForbids),
                error.UnknownTerminal => failure(error.UnknownTerminal),
                error.NotPermitted => failure(error.NotPermitted),
            };
            return .ok;
        },

        .clock_in => |p| {
            bus.clockOn(p.id) catch return failure(error.UnknownTerminal);
            return .ok;
        },

        .get_work_mode => |p| {
            const e = bus.get(p.id) orelse return failure(error.UnknownTerminal);
            return .{ .work_mode = e.work_mode };
        },

        .set_quiescence_threshold => |p| {
            host.setThreshold(p.id, p.ms) catch
                return hostFailure("ThresholdFailed", "could not change that threshold");
            return .ok;
        },

        .set_watch => |p| {
            // The host goes first, because it is the side that knows
            // whether this id is a terminal at all. Recording the bus entry
            // first would leave a phantom behind when it is not -- one that
            // shows up in `terminal_list` and can never be read.
            host.setWatching(p.id, p.watch) catch
                return failure(error.UnknownTerminal);

            if (p.watch) {
                bus.watch(p.id, caller) catch |err| switch (err) {
                    // Two supervisors typing into one input box is, to the
                    // agent in it, being given orders by two people at
                    // once. Refused rather than silently taken over.
                    error.AlreadyWatched => return failure(error.NotYours),
                    error.OutOfMemory => return hostFailure(
                        "WatchFailed",
                        "could not watch that terminal",
                    ),
                };
            } else {
                // Only the supervisor minding it may let it go.
                if (!bus.minds(caller, p.id)) return failure(error.NotYours);
                bus.unwatch(p.id);
            }

            return .ok;
        },

        .set_work_mode => |p| {
            const mode = std.meta.stringToEnum(Bus.WorkMode, p.mode) orelse
                return hostFailure(
                    "BadParams",
                    "mode must be clock_off, infinite_directed or infinite_sequential",
                );

            bus.setWorkMode(p.id, mode, .supervisor) catch |err| switch (err) {
                error.UnknownTerminal => return failure(error.UnknownTerminal),

                // Deliberately a distinct message. "Not permitted" alone
                // reads as a bug in the caller; this is the user having
                // said something the supervisor does not get to unsay.
                error.NotPermitted => return hostFailure(
                    "StandingInstruction",
                    "the user put this terminal in an infinite work mode; " ++
                        "only they can take it out of one",
                ),
            };

            return .ok;
        },

        .skill_read => |p| {
            const body = host.readSkill(alloc, p.name) catch
                return hostFailure("NoSuchSkill", "no skill by that name");
            return .{ .skill = .{ .name = p.name, .body = body } };
        },

        .group_create => |p| {
            host.chatCreate(p.group, caller) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_destroy => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatDestroy(p.group) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_add => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatAdd(p.group, p.id, p.history) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_remove => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatRemove(p.group, p.id) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_compact => |p| {
            host.chatCompact(p.group, p.through, p.summary, caller) catch |err|
                return chatFailure(err);
            return .ok;
        },

        .group_list => {
            // The brief goes to the supervisor, who wrote it, and to the
            // person at the keyboard, whose machine this is -- they face
            // the same question of what a group called "build" was for.
            //
            // Not to the other members. The reason is not secrecy: it is
            // that a note you might have to justify to your peers stops
            // being worth writing, and this one's whole value is that it
            // can be written carelessly.
            const want_brief = bus.isSupervisor(caller) or
                caller == Chat.user_id;

            const groups = host.chatGroupInfo(alloc, caller, want_brief) catch
                return hostFailure("ListFailed", "could not list groups");
            return .{ .groups = groups };
        },

        .group_post => |p| {
            host.chatPost(p.group, caller, p.text) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_read => |p| {
            const lines = host.chatRead(alloc, p.group, caller, p.since) catch |err|
                return chatFailure(err);
            return .{ .messages = capMessages(lines) };
        },
    }
}

fn lessById(_: void, a: wire.TerminalInfo, b: wire.TerminalInfo) bool {
    return a.id < b.id;
}

fn describe(bus: *const Bus, host: Host, id: Bus.Id) wire.TerminalInfo {
    // A terminal with no entry is one nobody has put under watch. It gets
    // its identity and nothing else: quiet time is not measured for it, and
    // saying `0` would claim it was busy this instant.
    const e = bus.get(id) orelse return .{ .id = id };

    return .{
        .id = id,
        .role = e.role,
        .duty = e.duty,
        .work_mode = e.work_mode,
        .quiet_ms = host.quietMs(id),
        .watching = e.role == .watched,
        .rounds = e.rounds,
    };
}

fn failure(err: Error) wire.Response {
    return .{ .failed = .{ .code = @errorName(err), .message = errorMessage(err) } };
}

/// Turn what the chat log refused into something an agent can act on.
fn chatFailure(err: anyerror) wire.Response {
    return switch (err) {
        error.NoSuchGroup => hostFailure("NoSuchGroup", "no group by that name"),
        error.GroupExists => hostFailure("GroupExists", "a group by that name already exists"),
        error.NotAMember => hostFailure("NotAMember", "you are not in that group"),
        error.TooManyGroups => hostFailure("TooManyGroups", "there are already too many groups"),
        error.BadName => hostFailure("BadName", "group names may use lowercase letters, digits and dashes"),
        error.Empty => hostFailure("Empty", "there is nothing there to send or to compact"),
        else => hostFailure("ChatFailed", "the group could not do that"),
    };
}

fn hostFailure(code: []const u8, message: []const u8) wire.Response {
    return .{ .failed = .{ .code = code, .message = message } };
}

// -- dispatch tests ---------------------------------------------------------

/// A host that records what it was asked to do and can be told to refuse.
const FakeHost = struct {
    sent: ?struct { id: Bus.Id, text: []const u8, submit: bool } = null,
    set_to: ?struct { id: Bus.Id, ms: u64 } = null,
    read_count: usize = 0,
    refuse: bool = false,
    posted: ?struct { group: []const u8, from: Bus.Id, text: []const u8 } = null,
    added: ?struct { group: []const u8, id: Bus.Id, history: History } = null,
    compacted: ?struct { group: []const u8, through: u64, summary: []const u8, by: Bus.Id } = null,
    read_group: ?[]const u8 = null,
    quiet_ms: u64 = 0,

    /// What `notices` hands back, and how many times it was asked.
    notices: []const u8 = "",
    drained: usize = 0,

    /// The last brief that was written, if any.
    brief_set: ?struct { group: []const u8, text: []const u8 } = null,

    /// What `session_recall` hands back.
    session: []const u8 = "",

    /// The reason of the last notification asked for.
    notified: ?[]const u8 = null,

    /// What is on screen, whether or not the bus knows about any of it.
    open: []const Place = &.{},

    /// Whether the last `set_watch` asked to start or stop sampling.
    watching: ?bool = null,

    /// Who the fake says made every group. Null means the usual boss.
    group_owner: ?Bus.Id = null,

    fn host(self: *FakeHost) Host {
        return .{ .ctx = self, .vtable = &.{
            .readTerminal = read,
            .sendText = send,
            .quietMs = quietMs,
            .openTerminals = openTerminals,
            .setWatching = setWatching,
            .drainNotices = drainNotices,
            .setThreshold = setThreshold,
            .readSkill = readSkill,
            .chatCreate = chatCreate,
            .chatDestroy = chatDestroy,
            .chatAdd = chatAdd,
            .chatRemove = chatRemove,
            .chatCompact = chatCompact,
            .chatPost = chatPost,
            .notifyUser = notifyUser,
            .sessionRecall = sessionRecall,
            .chatSetBrief = chatSetBrief,
            .chatGroupInfo = chatGroupInfo,
            .chatOwner = chatOwner,
            .chatMembers = chatMembers,
            .chatGroups = chatGroups,
            .chatRead = chatRead,
        } };
    }

    fn chatOwner(ctx: *anyopaque, _: []const u8) anyerror!Bus.Id {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return self.group_owner orelse boss;
    }

    fn chatCreate(ctx: *anyopaque, _: []const u8, _: Bus.Id) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.GroupExists;
    }

    fn chatDestroy(ctx: *anyopaque, _: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
    }

    fn chatAdd(
        ctx: *anyopaque,
        group: []const u8,
        id: Bus.Id,
        history: History,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.added = .{ .group = group, .id = id, .history = history };
    }

    fn chatRemove(ctx: *anyopaque, _: []const u8, _: Bus.Id) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
    }

    fn chatCompact(
        ctx: *anyopaque,
        group: []const u8,
        through: u64,
        summary: []const u8,
        by: Bus.Id,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.compacted = .{
            .group = group,
            .through = through,
            .summary = summary,
            .by = by,
        };
    }

    fn chatPost(
        ctx: *anyopaque,
        group: []const u8,
        from: Bus.Id,
        text: []const u8,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.posted = .{ .group = group, .from = from, .text = text };
    }

    fn chatGroupInfo(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
        want_brief: bool,
    ) anyerror![]ChatGroupInfo {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.ListFailed;

        const out = try alloc.alloc(ChatGroupInfo, 1);
        out[0] = .{
            .name = try alloc.dupe(u8, "build"),
            .brief = if (want_brief)
                try alloc.dupe(u8, "写 retry 装饰器")
            else
                "",
        };
        return out;
    }

    fn notifyUser(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        reason: []const u8,
        _: []const u8,
        _: []const u8,
        _: Bus.Id,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NotifyFailed;
        self.notified = reason;
        return alloc.dupe(u8, "sent to 1 of 1");
    }

    fn sessionRecall(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.ReadFailed;
        return alloc.dupe(u8, self.session);
    }

    fn chatSetBrief(ctx: *anyopaque, group: []const u8, text: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.brief_set = .{ .group = group, .text = text };
    }

    fn chatMembers(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: []const u8,
    ) anyerror![]const ChatMember {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;

        const out = try alloc.alloc(ChatMember, 1);
        out[0] = .{ .id = 0x9999, .title = try alloc.dupe(u8, "a terminal") };
        return out;
    }

    fn chatGroups(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
    ) anyerror![]const []const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;

        const names = try alloc.alloc([]const u8, 1);
        names[0] = try alloc.dupe(u8, "build");
        return names;
    }

    fn chatRead(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        group: []const u8,
        _: Bus.Id,
        since: u64,
    ) anyerror![]const ChatLine {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NotAMember;
        self.read_group = group;

        const one = try alloc.alloc(ChatLine, 1);
        one[0] = .{
            .seq = since + 1,
            .from = 0x9999,
            .author = try alloc.dupe(u8, "a terminal"),
            .at_ms = 0,
            .summary = false,
            .text = try alloc.dupe(u8, "hello"),
        };
        return one;
    }

    fn readSkill(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        return std.fmt.allocPrint(alloc, "prose for {s}", .{name});
    }

    fn read(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
        _: u16,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.read_count += 1;
        return alloc.dupe(u8, "screen contents");
    }

    fn send(ctx: *anyopaque, id: Bus.Id, text: []const u8, submit: bool) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.sent = .{ .id = id, .text = text, .submit = submit };
    }

    fn quietMs(ctx: *anyopaque, _: Bus.Id) u64 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return self.quiet_ms;
    }

    fn openTerminals(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
    ) anyerror![]const Place {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return alloc.dupe(Place, self.open);
    }

    fn setWatching(ctx: *anyopaque, _: Bus.Id, watching: bool) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.watching = watching;
    }

    fn drainNotices(ctx: *anyopaque, alloc: std.mem.Allocator, _: Bus.Id) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.drained += 1;
        return alloc.dupe(u8, self.notices);
    }

    fn setThreshold(ctx: *anyopaque, id: Bus.Id, ms: u64) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.set_to = .{ .id = id, .ms = ms };
    }
};

test "dispatch refuses an unauthorized request before touching the host" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .terminal_read = .{ .id = boss },
    });

    try testing.expectEqualStrings("NotPermitted", res.failed.code);
    try testing.expectEqual(@as(usize, 0), fake.read_count);
}

test "the supervisor can read and type into a watched terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const read = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .terminal_read = .{ .id = worker },
    });
    defer testing.allocator.free(read.text);
    try testing.expectEqualStrings("screen contents", read.text);

    const sent = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .terminal_send = .{ .id = worker, .text = "继续", .submit = true },
    });
    try testing.expect(sent == .ok);
    try testing.expectEqualStrings("继续", fake.sent.?.text);
    try testing.expectEqual(worker, fake.sent.?.id);
}

test "a host refusal comes back as a failure the agent can read" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .terminal_send = .{ .id = worker, .text = "x" },
    });
    try testing.expectEqualStrings("SendFailed", res.failed.code);
    try testing.expect(res.failed.message.len > 0);
}

test "clock_out through dispatch still obeys the work mode ban" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try b.setWorkMode(worker, .infinite_sequential, .user);
    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .clock_out = .{ .id = worker },
    });

    try testing.expectEqualStrings("WorkModeForbids", res.failed.code);
    try testing.expectEqual(Bus.Duty.on, b.get(worker).?.duty);
}

test "terminal_list is sorted so two listings can be compared" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.watch(0xaaaa, boss);
    try b.watch(0x0001, boss);

    const open = [_]Place{
        .{ .id = 0xaaaa }, .{ .id = 0x0001 }, .{ .id = boss }, .{ .id = worker },
    };
    var fake: FakeHost = .{ .open = &open };

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .terminal_list);
    defer testing.allocator.free(res.terminals);

    try testing.expect(res.terminals.len >= 4);
    for (res.terminals[1..], 0..) |info, i| {
        try testing.expect(res.terminals[i].id < info.id);
    }
}

test "a terminal nobody is watching is still listed, with where it is" {
    // The restore case, and the reason this list stopped coming from the
    // bus. After a restart nothing is under watch -- so a list built from
    // the bus is empty exactly when the supervisor needs it to match last
    // night's notes against what is on screen.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    const open = [_]Place{
        .{ .id = boss, .cwd = "/work", .title = "supervisor" },
        .{ .id = 0x5151, .cwd = "/work/alpha", .title = "◑ colstat" },
    };
    var fake: FakeHost = .{ .open = &open, .quiet_ms = 4242 };

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .terminal_list);
    defer testing.allocator.free(res.terminals);

    var found: ?wire.TerminalInfo = null;
    for (res.terminals) |info| if (info.id == 0x5151) {
        found = info;
    };
    const stranger = found orelse return error.NotListed;

    // Enough to put it back: where it was, and what it was called.
    try testing.expectEqualStrings("/work/alpha", stranger.cwd);
    try testing.expectEqualStrings("◑ colstat", stranger.title);

    // And nothing that would have to be measured to be true. The fake
    // would happily answer 4242ms; a terminal nobody samples has no
    // quiet time, and `0` would read as "busy this instant".
    try testing.expect(!stranger.watching);
    try testing.expectEqual(Bus.Role.none, stranger.role);
    try testing.expect(stranger.quiet_ms == null);
    try testing.expect(stranger.rounds == null);
}

test "me works for a terminal that supervises nothing" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .quiet_ms = 4242 };

    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .me);
    try testing.expectEqual(worker, res.me.id);
    try testing.expectEqual(Bus.Role.watched, res.me.role);
    try testing.expectEqual(@as(u64, 4242), res.me.quiet_ms);
    try testing.expect(res.me.watching);
}

test "any terminal may read a skill" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    // A watched terminal can read how supervision works. These are
    // instructions, not reach, and refusing would mean an agent cannot find
    // out why it was nudged.
    const res = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .skill_read = .{ .name = "supervising" },
    });
    defer testing.allocator.free(res.skill.body);
    try testing.expectEqualStrings("supervising", res.skill.name);
    try testing.expectEqualStrings("prose for supervising", res.skill.body);
}

test "an unknown skill fails rather than returning nothing" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .skill_read = .{ .name = "no-such-skill" },
    });
    try testing.expectEqualStrings("NoSuchSkill", res.failed.code);
}

test "get_work_mode reads but nothing writes" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try b.setWorkMode(worker, .infinite_directed, .user);
    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .get_work_mode = .{ .id = worker },
    });
    try testing.expectEqual(Bus.WorkMode.infinite_directed, res.work_mode);
}

test "reading the notices is the supervisor's alone" {
    // A watched terminal reading the supervisor's box would learn which of
    // its peers had gone quiet and for how long -- a picture of the whole
    // room that its own role never granted it.
    try testing.expect(requiresSupervisor(.notices));
}

test "notices hands back what is waiting and clears it" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(boss);

    var fake: FakeHost = .{ .notices = "[poltergeist] 0x2222 quiet 90s" };
    const host = fake.host();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, host, boss, .notices);
    try testing.expectEqualStrings("[poltergeist] 0x2222 quiet 90s", res.text);
    try testing.expectEqual(@as(usize, 1), fake.drained);
}

test "an empty box is an answer, not a failure" {
    // The supervisor asked and nothing is waiting. That is worth saying
    // plainly rather than as an error it would have to interpret.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(boss);

    var fake: FakeHost = .{};
    const host = fake.host();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, host, boss, .notices);
    try testing.expectEqualStrings("", res.text);
}

test "a group's brief is the supervisor's alone to write" {
    // Saying what a group is for is arranging it, which is the same
    // authority as making one.
    try testing.expect(requiresSupervisor(.group_set_brief));
}

test "only the supervisor's listing carries the brief" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The supervisor sees what it wrote.
    const mine = try dispatch(alloc, &b, fake.host(), boss, .group_list);
    try testing.expect(mine.groups[0].brief.len > 0);

    // A member gets the group but not the note. Not an error -- asking
    // which groups you are in is a fair question.
    const theirs = try dispatch(alloc, &b, fake.host(), worker, .group_list);
    try testing.expectEqualStrings("build", theirs.groups[0].name);
    try testing.expectEqualStrings("", theirs.groups[0].brief);
}

test "setting a brief reaches the host with what was written" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, fake.host(), boss, .{
        .group_set_brief = .{ .group = "build", .text = "写 retry 装饰器" },
    });
    try testing.expectEqual(wire.Response.ok, res);
    try testing.expectEqualStrings("build", fake.brief_set.?.group);
    try testing.expectEqualStrings("写 retry 装饰器", fake.brief_set.?.text);
}

test "the person at the keyboard sees the brief too" {
    // Not because they wrote it, but because it is their machine and they
    // face the same question the supervisor does: what was "build" for?
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(
        arena.allocator(),
        &b,
        fake.host(),
        Chat.user_id,
        .group_list,
    );
    try testing.expect(res.groups[0].brief.len > 0);
}

test "a reply is capped so it cannot outgrow the line buffer" {
    // The failure this prevents is not a slow reply, it is `StreamTooLong`
    // and a connection that never recovers: the next attempt asks for the
    // same range and fails the same way. It took a few days of real use to
    // reach, because it needs a group with a few hundred long messages in
    // it.
    const big = "x" ** 8192;

    var lines: [64]ChatLine = undefined;
    for (&lines, 0..) |*line, i| line.* = .{
        .seq = i,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = big,
    };

    const kept = capMessages(&lines);
    try testing.expect(kept.len < lines.len);

    var total: usize = 0;
    for (kept) |line| total += line.text.len + line.author.len;

    // Inside the budget, and not so far inside that a caller polling one
    // instalment at a time would be here all day.
    try testing.expect(total <= read_budget_bytes + big.len);
    try testing.expect(kept.len > 1);
}

test "one message larger than the whole budget is still delivered" {
    // Returning nothing would leave the caller polling forever with a
    // cursor that never moves -- a quieter failure than the one this
    // replaced, and a worse one.
    const huge = "y" ** (128 * 1024);
    const lines = [_]ChatLine{.{
        .seq = 1,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = huge,
    }};

    try testing.expectEqual(@as(usize, 1), capMessages(&lines).len);
}

test "a reply that fits is passed through whole" {
    const lines = [_]ChatLine{
        .{ .seq = 1, .from = 1, .author = "a", .at_ms = 0, .summary = false, .text = "hello" },
        .{ .seq = 2, .from = 2, .author = "b", .at_ms = 0, .summary = false, .text = "there" },
    };
    try testing.expectEqual(@as(usize, 2), capMessages(&lines).len);
}

test "set_watch works on a terminal nobody is watching, which is the point" {
    // The bug this catches: every other tool here acts on a terminal
    // already under supervision, so the permission check required the
    // target to be known -- and `set_watch` inherited it. That made it
    // refuse every terminal it was for, because a terminal you are about
    // to start watching is by definition not being watched yet.
    //
    // The first version of this test used a terminal the fixture had
    // already watched, and passed while the tool was unusable.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    const stranger: Bus.Id = 0x5151;
    try testing.expect(b.get(stranger) == null);

    try authorize(&b, boss, .{ .set_watch = .{ .id = stranger, .watch = true } });
}

test "only the supervisor may start watching a terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(
        error.NotPermitted,
        authorize(&b, worker, .{ .set_watch = .{ .id = 0x5151, .watch = true } }),
    );
}

test "a supervisor cannot put itself under its own supervision" {
    // A knot rather than a feature: the supervisor is not one of the
    // terminals it watches, and the keybind path says so too.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(
        error.SelfTarget,
        authorize(&b, boss, .{ .set_watch = .{ .id = boss, .watch = true } }),
    );
}

test "setting a work mode still requires a terminal under supervision" {
    // The exemption is `set_watch`'s alone. A work mode is a thing you say
    // about a terminal you are minding, and the bus has nowhere to record
    // it for one you are not.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(
        error.UnknownTerminal,
        authorize(&b, boss, .{ .set_work_mode = .{
            .id = 0x5151,
            .mode = "clock_off",
        } }),
    );
}

test "a group belongs to the supervisor that made it" {
    // With one supervisor this could not come up. With several, any of
    // them could otherwise destroy another's group or pull terminals out
    // of it, and the first anybody would know is that a conversation had
    // stopped working.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.addSupervisor(other);

    var fake: FakeHost = .{ .group_owner = boss };

    // The one that made it may rearrange it.
    _ = try dispatch(testing.allocator, &b, fake.host(), boss, .{
        .group_set_brief = .{ .group = "build", .text = "what this is for" },
    });

    // The other supervisor may not, however senior it feels.
    const refused = try dispatch(testing.allocator, &b, fake.host(), other, .{
        .group_destroy = .{ .group = "build" },
    });
    try testing.expectEqualStrings("NotYours", refused.failed.code);
}

test "talking in a group you were added to is not rearranging it" {
    // Membership and ownership are different things: the point of a group
    // is that the terminals in it can talk, and only the arranging is the
    // supervisor's.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    var fake: FakeHost = .{ .group_owner = other };

    _ = try dispatch(testing.allocator, &b, fake.host(), worker, .{
        .group_post = .{ .group = "build", .text = "signature is settled" },
    });
}
