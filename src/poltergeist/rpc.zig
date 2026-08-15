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
    };
}

/// Whether a method targets another terminal, and so must be checked
/// against the bus for existence.
pub fn targetsTerminal(method: Method) bool {
    return switch (method) {
        .me, .terminal_list => false,
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
        .me, .terminal_list => null,
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

test "every method except me needs the supervisor" {
    for (std.enums.values(Method)) |m| {
        const expected = m != .me;
        try testing.expectEqual(expected, requiresSupervisor(m));
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
