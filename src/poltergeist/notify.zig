//! Telling the person when something needs them.
//!
//! The decision of *whether* to tell them lives here; the sending is done
//! by plugins, because the useful channels reach a phone and there are
//! dozens of those with protocols that keep changing.
//!
//! **Nothing here forks a process any more.** A notification is published
//! on the feed like anything else and picked up by whichever resident
//! plugins subscribed to `terminal.quiet`; see `Resident.zig` for what that
//! costs and what it buys. What did *not* move is the decision above: the
//! hour, the two reasons, and "there is nowhere to send this" are still
//! settled here and settled before anything is published.
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
const Feed = @import("Feed.zig");
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

/// This event as the feed publishes it.
///
/// Rendering the JSON is not here any more and is not anywhere twice: a
/// notification is one kind of event on the one stream, and `Resident`
/// writes every kind. This is the whole of what used to be `notify.body` --
/// the fields, once, in the place that knows what a notification is.
pub fn published(event: Event) Feed.Event {
    return .{ .terminal_quiet = .{
        .at_ms = event.at_ms,
        .reason = switch (event.reason) {
            .scheduling => "scheduling",
            .authorisation => "authorisation",
        },
        .title = event.title,
        .body = event.body,
        .terminal = event.terminal,
        .terminal_name = event.terminal_name,
    } };
}

/// How many of these plugins asked to be handed `e`.
///
/// This replaces counting by kind, and the difference is the point: there
/// is no kind to count, so there is no list of kinds to forget one from.
/// A plugin is a notification channel exactly when it subscribed to
/// `terminal.quiet` -- which is a thing its own manifest says, in the one
/// place that decides what it is handed.
pub fn count(plugins: []const Plugin.Manifest, e: Plugin.Event) usize {
    var n: usize = 0;
    for (plugins) |manifest| {
        if (manifest.wants.subscribes(e)) n += 1;
    }
    return n;
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

test "a published notification carries the reason, the terminal and its name" {
    const ev = published(.{
        .reason = .authorisation,
        .title = "worker-core 需要确认",
        .body = "它停在一个工具授权提示上",
        .terminal = 0x9491465653644ed0,
        .terminal_name = "✳ Write retry.py",
        .at_ms = 1786819271275,
    });

    try testing.expectEqual(Plugin.Event.terminal_quiet, ev.kind());
    try testing.expectEqualStrings("authorisation", ev.terminal_quiet.reason);
    try testing.expectEqual(@as(u64, 0x9491465653644ed0), ev.terminal_quiet.terminal);
    try testing.expectEqualStrings("✳ Write retry.py", ev.terminal_quiet.terminal_name);

    // A notification is in no group, and that must not read as "in every
    // group": `Resident.forThisPlugin` lets it through on the strength of
    // the subscription alone.
    try testing.expect(ev.group() == null);
}

test "what a plugin is handed is what it subscribed to, and nothing else" {
    // The whole of what `Kind` used to decide. An archive is not a
    // notification channel -- not because it is called an archive, but
    // because its manifest never asked for `terminal.quiet`.
    const plugins = [_]Plugin.Manifest{
        .{
            .key = "chat-archive",
            .exec = "/nonexistent",
            .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        },
        .{
            .key = "feishu",
            .exec = "/nonexistent",
            .wants = .{ .events = &.{.terminal_quiet} },
        },
        .{
            // One plugin, two subscriptions. Under `Kind` this needed two
            // plugins and a new enum member to even be expressible.
            .key = "both",
            .exec = "/nonexistent",
            .wants = .{ .events = &.{ .chat, .terminal_quiet }, .groups = &.{"*"} },
        },
    };

    try testing.expectEqual(@as(usize, 2), count(&plugins, .terminal_quiet));
    try testing.expectEqual(@as(usize, 2), count(&plugins, .chat));
    try testing.expectEqual(@as(usize, 0), count(&plugins, .provision));
}
