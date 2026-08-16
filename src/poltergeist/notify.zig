//! Telling the person when something needs them.
//!
//! The decision of *whether* to tell them lives here; the sending is done
//! by plugins (`Plugin.zig`), because the useful channels reach a phone
//! and there are dozens of those with protocols that keep changing.
//!
//! Two kinds of thing need a person, and they are not alike:
//!
//!   - **A scheduling question** -- keep going, change tack, give up. The
//!     supervisor can answer these; that is what it is for. Outside the
//!     window it does, and says so in the group.
//!   - **A tool authorisation** -- "may I write this file". Nobody may
//!     answer that for somebody else (R2), so there is no third option:
//!     either the person is told, or the terminal sits there until
//!     morning. These go out whatever the hour.
//!
//! That distinction came from watching a real run: a worker stopped on an
//! MCP authorisation prompt and the supervisor correctly refused to touch
//! it -- and the terminal then sat there, because there was nowhere for
//! the question to go. See `docs/poltergeist/supervisor.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Plugin = @import("Plugin.zig");

const log = std.log.scoped(.poltergeist);

/// Why somebody is being told.
pub const Reason = enum {
    /// Keep going, change direction, stop. The supervisor may answer this
    /// one, and outside the window it does.
    scheduling,

    /// A permission prompt. Nobody answers these for anybody else, so it
    /// is told at any hour or not at all.
    authorisation,

    /// Whether the quiet-hours window applies to this at all.
    pub fn respectsWindow(self: Reason) bool {
        return switch (self) {
            .scheduling => true,
            .authorisation => false,
        };
    }
};

/// One occasion for telling somebody something.
pub const Event = struct {
    reason: Reason,
    title: []const u8,
    body: []const u8,

    /// Which terminal this is about, and what it is called.
    terminal: Bus.Id = 0,
    terminal_name: []const u8 = "",

    /// Unix milliseconds.
    at_ms: i64 = 0,
};

/// A window of hours, in minutes since midnight, local time.
///
/// `start > end` means it wraps midnight -- `22:00-07:00` is a perfectly
/// ordinary thing to write and would otherwise be an empty window.
pub const Window = struct {
    start_min: u16,
    end_min: u16,

    /// Parse `HH:MM-HH:MM`. Null when the text is empty or malformed.
    ///
    /// A malformed window reads as "no window", which is to say "any hour
    /// is fine". The alternative -- treating it as "no hour is fine" --
    /// would silence every notification because of a typo, and the whole
    /// point of this feature is that it works on the night nobody checked.
    pub fn parse(text: []const u8) ?Window {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return null;

        const dash = std.mem.indexOfScalar(u8, trimmed, '-') orelse {
            log.warn("notify: window wants HH:MM-HH:MM, got {s}", .{trimmed});
            return null;
        };

        const start = parseClock(trimmed[0..dash]) orelse return null;
        const end = parseClock(trimmed[dash + 1 ..]) orelse return null;
        return .{ .start_min = start, .end_min = end };
    }

    fn parseClock(text: []const u8) ?u16 {
        const trimmed = std.mem.trim(u8, text, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;

        const h = std.fmt.parseInt(u16, trimmed[0..colon], 10) catch return null;
        const m = std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10) catch return null;
        if (h > 23 or m > 59) return null;

        return h * 60 + m;
    }

    /// Whether `minute` (since local midnight) falls inside.
    pub fn contains(self: Window, minute: u16) bool {
        if (self.start_min <= self.end_min) {
            return minute >= self.start_min and minute < self.end_min;
        }
        // Wraps midnight.
        return minute >= self.start_min or minute < self.end_min;
    }
};

/// What to do about one event.
pub const Verdict = enum {
    /// Send it.
    tell,

    /// Inside quiet hours and answerable by the supervisor: leave it to
    /// the supervisor rather than waking anybody.
    leave_to_supervisor,

    /// Nowhere to send it. Not the same as "not worth sending": the
    /// caller should say so somewhere the supervisor can see.
    nowhere_to_send,
};

/// Decide what happens to an event.
///
/// `now_min` is minutes since local midnight. Kept as a parameter rather
/// than read here so this stays testable without a clock.
pub fn decide(
    event: Event,
    window: ?Window,
    now_min: u16,
    plugin_count: usize,
) Verdict {
    if (plugin_count == 0) return .nowhere_to_send;

    const w = window orelse return .tell;
    if (!event.reason.respectsWindow()) return .tell;
    if (w.contains(now_min)) return .tell;

    return .leave_to_supervisor;
}

/// Render an event as the JSON body a plugin receives.
///
/// Parameters are not here: `Plugin.call` adds those after resolving them,
/// so nothing secret passes through this function at all.
pub fn body(alloc: Allocator, event: Event) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;

    s.objectField("event") catch return error.OutOfMemory;
    s.write(switch (event.reason) {
        .scheduling => "scheduling",
        .authorisation => "authorisation",
    }) catch return error.OutOfMemory;

    s.objectField("title") catch return error.OutOfMemory;
    s.write(event.title) catch return error.OutOfMemory;
    s.objectField("body") catch return error.OutOfMemory;
    s.write(event.body) catch return error.OutOfMemory;

    s.objectField("terminal") catch return error.OutOfMemory;
    s.print("\"0x{x:0>16}\"", .{event.terminal}) catch return error.OutOfMemory;
    s.objectField("terminal_name") catch return error.OutOfMemory;
    s.write(event.terminal_name) catch return error.OutOfMemory;

    s.objectField("at_ms") catch return error.OutOfMemory;
    s.write(event.at_ms) catch return error.OutOfMemory;

    s.endObject() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What came of trying to tell somebody.
pub const Delivery = struct {
    /// How many plugins said they did it.
    delivered: usize = 0,

    /// How many did not, for any reason.
    failed: usize = 0,
};

/// Send an event through every configured plugin.
///
/// **All of them, not the first that works.** The scenario is one where a
/// broken channel goes unnoticed for hours; two notifications is a much
/// smaller cost than the one that never arrived. It also means one locked
/// vault does not silence the rest.
pub fn send(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    plugins: []const Plugin.Manifest,
    params_for: *const fn (
        ctx: *anyopaque,
        alloc: Allocator,
        key: []const u8,
    ) anyerror![]const Plugin.Param,
    ctx: *anyopaque,
    event: Event,
) Delivery {
    var result: Delivery = .{};

    const rendered = body(alloc, event) catch return result;
    defer alloc.free(rendered);

    for (plugins) |manifest| {
        const params = params_for(ctx, alloc, manifest.key) catch &.{};

        switch (Plugin.call(manifest, alloc, io, env, rendered, params)) {
            .done => result.delivered += 1,
            else => |outcome| {
                result.failed += 1;
                log.warn(
                    "notify: {s} did not deliver ({t})",
                    .{ manifest.key, outcome },
                );
            },
        }
    }

    return result;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "a window is parsed, and a broken one reads as no window" {
    const w = Window.parse("09:00-22:00").?;
    try testing.expectEqual(@as(u16, 540), w.start_min);
    try testing.expectEqual(@as(u16, 1320), w.end_min);

    // Anything unparseable means "any hour is fine". Silencing every
    // notification over a typo would break exactly the night nobody
    // checked the config.
    try testing.expect(Window.parse("") == null);
    try testing.expect(Window.parse("nonsense") == null);
    try testing.expect(Window.parse("9-22") == null);
    try testing.expect(Window.parse("25:00-26:00") == null);
}

test "a window that wraps midnight is an ordinary window" {
    const w = Window.parse("22:00-07:00").?;

    try testing.expect(w.contains(23 * 60));
    try testing.expect(w.contains(3 * 60));
    try testing.expect(!w.contains(12 * 60));
}

test "a scheduling question at 3am is left to the supervisor" {
    const w = Window.parse("09:00-22:00").?;
    const e: Event = .{ .reason = .scheduling, .title = "t", .body = "b" };

    try testing.expectEqual(
        Verdict.leave_to_supervisor,
        decide(e, w, 3 * 60, 1),
    );
    try testing.expectEqual(Verdict.tell, decide(e, w, 10 * 60, 1));
}

test "an authorisation prompt at 3am is sent anyway" {
    // Nobody may answer these for somebody else, so the choice is not
    // "disturb them or decide for them" -- it is "disturb them or let the
    // terminal sit until morning".
    const w = Window.parse("09:00-22:00").?;
    const e: Event = .{ .reason = .authorisation, .title = "t", .body = "b" };

    try testing.expectEqual(Verdict.tell, decide(e, w, 3 * 60, 1));
}

test "with nothing configured there is nowhere to send" {
    const e: Event = .{ .reason = .authorisation, .title = "t", .body = "b" };
    try testing.expectEqual(Verdict.nowhere_to_send, decide(e, null, 3 * 60, 0));
}

test "the body says which kind it is, and names the terminal" {
    const rendered = try body(testing.allocator, .{
        .reason = .authorisation,
        .title = "worker-core 需要确认",
        .body = "它停在一个工具授权提示上",
        .terminal = 0x9491465653644ed0,
        .terminal_name = "✳ Write retry.py",
        .at_ms = 1786819271275,
    });
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "\"event\":\"authorisation\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "0x9491465653644ed0") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "✳ Write retry.py") != null);

    // Nothing secret goes through here; parameters are added later, after
    // they have been resolved.
    try testing.expect(std.mem.indexOf(u8, rendered, "params") == null);
}
