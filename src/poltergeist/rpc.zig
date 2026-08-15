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

pub const Method = enum {
    /// Which terminal am I, what is my role, what work mode am I under.
    me,

    /// Every terminal the bus knows about, with its quiescence duration and
    /// duty state. Durations and bookkeeping only -- never screen contents.
    terminal_list,

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

    /// Read one of Poltergeist's skills: the text describing how to do this
    /// job. Any terminal may read one; they are instructions, not reach.
    skill_read,
};

pub const Request = union(Method) {
    me,
    terminal_list,
    terminal_read: struct { id: Bus.Id, lines: u16 = 0 },
    terminal_send: struct { id: Bus.Id, text: []const u8, submit: bool = true },
    clock_out: struct { id: Bus.Id, reason: []const u8 = "" },
    clock_in: struct { id: Bus.Id },
    get_work_mode: struct { id: Bus.Id },
    set_quiescence_threshold: struct { id: Bus.Id, ms: u64 },
    skill_read: struct { name: []const u8 },
};

pub const Error = error{
    /// The caller's role does not permit this method.
    NotPermitted,

    /// No terminal by that id.
    UnknownTerminal,

    /// The terminal's work mode forbids clocking off.
    WorkModeForbids,

    /// A terminal may not act on itself through this surface.
    SelfTarget,
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
        .terminal_read,
        .terminal_send,
        .clock_out,
        .clock_in,
        .get_work_mode,
        .set_quiescence_threshold,
        => true,

        // Skills are instructions, not reach. A watched terminal reading
        // how supervision works learns nothing it could not be told, and
        // refusing would mean an agent cannot find out why it was nudged.
        .skill_read => false,
    };
}

/// Whether a method targets another terminal, and so must be checked
/// against the bus for existence.
pub fn targetsTerminal(method: Method) bool {
    return switch (method) {
        .me, .terminal_list, .skill_read => false,
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
        .me, .terminal_list, .skill_read => null,
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

    if (requiresSupervisor(method)) {
        const supervisor = bus.supervisor orelse return error.NotPermitted;
        if (supervisor != caller) return error.NotPermitted;
    }

    if (target(req)) |id| {
        // The supervisor reaching into itself is always a mistake, and an
        // agent typing into its own terminal through this surface would be
        // a loop with no natural end.
        if (id == caller) return error.SelfTarget;
        if (bus.get(id) == null) return error.UnknownTerminal;
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
        error.NotPermitted => "not permitted: only the supervisor may do this",
        error.UnknownTerminal => "no terminal with that id",
        error.WorkModeForbids => "this terminal runs in an infinite work mode and cannot clock out; only the user can change that",
        error.SelfTarget => "a terminal cannot target itself",
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
    try b.setSupervisor(boss);
    try b.watch(worker);
    return b;
}

test "only asking about yourself and reading instructions is open to all" {
    // Everything that reaches another terminal needs the supervisor.
    // Knowing who you are and reading how the job works do not reach
    // anything, so they are open.
    for (std.enums.values(Method)) |m| {
        const open = switch (m) {
            .me, .skill_read => true,
            else => false,
        };
        try testing.expectEqual(!open, requiresSupervisor(m));
    }
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
    try b.watch(worker);

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

test "there is no way to change a work mode through this surface" {
    // The ban on clocking off an infinite-mode terminal is only worth
    // something if the mode itself is out of reach here. If a `set_work_mode`
    // method ever appears, this test should be the thing that objects.
    for (std.enums.values(Method)) |m| {
        try testing.expect(!std.mem.eql(u8, @tagName(m), "set_work_mode"));
    }
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

test "a terminal that stopped being watched loses nothing it never had" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    b.unwatch(worker);

    // Still known to the bus, so the supervisor can still look at it; being
    // unwatched only stops it being reported, it does not hide it.
    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });

    // And it still cannot act on anyone.
    try testing.expectError(error.NotPermitted, authorize(&b, worker, .terminal_list));
}

test "a demoted supervisor immediately loses its reach" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, boss, .{ .terminal_read = .{ .id = worker } });

    try b.setSupervisor(other);
    try testing.expectError(error.NotPermitted, authorize(&b, boss, .{
        .terminal_read = .{ .id = worker },
    }));
    try authorize(&b, other, .{ .terminal_read = .{ .id = worker } });
}

// -- dispatch ---------------------------------------------------------------

const wire = @import("wire.zig");

/// What the app must supply for a request to be carried out.
///
/// An interface rather than a direct dependency on `App` so the dispatch
/// rules can be tested against a fake. It is deliberately narrow: reading a
/// screen, typing into one, and two numbers. Anything wider would invite
/// the tool surface to grow capabilities that were never argued for.
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

            var it = bus.entries.iterator();
            while (it.next()) |kv| {
                try list.append(alloc, describe(bus, host, kv.key_ptr.*));
            }

            // Sorted so that repeated calls read the same way; a hash map's
            // order is not stable and an agent comparing two listings would
            // see phantom movement.
            const owned = try list.toOwnedSlice(alloc);
            std.mem.sort(wire.TerminalInfo, owned, {}, lessById);
            return .{ .terminals = owned };
        },

        .terminal_read => |p| {
            const text = host.readTerminal(alloc, p.id, p.lines) catch
                return hostFailure("ReadFailed", "could not read that terminal");
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

        .skill_read => |p| {
            const body = host.readSkill(alloc, p.name) catch
                return hostFailure("NoSuchSkill", "no skill by that name");
            return .{ .skill = .{ .name = p.name, .body = body } };
        },
    }
}

fn lessById(_: void, a: wire.TerminalInfo, b: wire.TerminalInfo) bool {
    return a.id < b.id;
}

fn describe(bus: *const Bus, host: Host, id: Bus.Id) wire.TerminalInfo {
    const e = bus.get(id) orelse Bus.Entry{};
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
    quiet_ms: u64 = 0,

    fn host(self: *FakeHost) Host {
        return .{ .ctx = self, .vtable = &.{
            .readTerminal = read,
            .sendText = send,
            .quietMs = quietMs,
            .setThreshold = setThreshold,
            .readSkill = readSkill,
        } };
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
    try b.watch(0xaaaa);
    try b.watch(0x0001);
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), boss, .terminal_list);
    defer testing.allocator.free(res.terminals);

    try testing.expect(res.terminals.len >= 4);
    for (res.terminals[1..], 0..) |info, i| {
        try testing.expect(res.terminals[i].id < info.id);
    }
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
