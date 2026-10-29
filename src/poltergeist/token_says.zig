//! How many tokens an agent spent, and which stretch of work they belong to
//! (task 2584; the plan is `polter-artifacts/2433/PLAN.md` §2.2).
//!
//! `Tasks.spans` already answers **when each terminal held a place on a
//! task**. This file answers the other half: **what a session had spent by
//! then**, and therefore how much of it falls inside each of those
//! stretches.
//!
//! **Nothing here knows what Claude Code, Codex or opencode is.** A CLI's
//! plugin declares, in its own `plugin.json`, where its numbers come from
//! and what they are called; this file reads that declaration and follows
//! it. A new CLI is a new `token_says` section, not a branch in the core --
//! the same split `screen_says`, `title_says` and `startup_says` already
//! follow (`dev-docs/poltergeist/plugins.md`).
//!
//! ## Two kinds of number that look alike
//!
//! **A count that only ever grows, and a level that goes up and down.** A
//! session's total spend is the first: what two readings differ by is what
//! was spent in between. Claude Code's status line hands over the second --
//! `context_window.current_usage` is *the last API call*, not what the
//! session has spent -- so subtracting two of those gives a number that
//! means nothing. The declaration says which one it is (`Counts`) and the
//! two are never mixed: over a stretch a `window` reading is **the level at
//! the end of it**, and a `total` reading is **what was spent during it**.
//! This is CLAUDE.md's rule about one flag answering two questions, applied
//! to a number.
//!
//! ## "No reading" is not zero
//!
//! A stretch no reading can speak for is `null`, never 0
//! (`dev-docs/poltergeist/control-room.md` §8.2: 「拿不到数的 CLI：那一行写
//! 「这家 CLI 的用量拿不到」和原因，不显示 0」). `totals` counts those
//! stretches, so a reader shows "100 over two of three stretches" rather
//! than "100" over a task the number does not cover.
//!
//! ## What a `total` stretch's number actually covers
//!
//! Readings arrive at points, and a stretch's boundaries rarely land on
//! them. The number for a stretch is therefore the difference between the
//! newest reading at or before its start and the newest reading at or
//! before its end -- the interval the readings really bracket, which
//! `read_at_ms` names, and which can begin before `from_ms`. Two
//! consequences, both deliberate:
//!
//!   * **Stretches that tile a session add up to its whole spend**, however
//!     badly the readings line up with the boundaries. That is what makes
//!     the per-place sums worth showing.
//!   * A stretch's own number can therefore be larger than what was spent
//!     inside it, by everything spent between `read_at_ms` and `from_ms`.
//!     `read_at_ms` is what lets a reader see that; a stretch nobody read
//!     during has no number at all.
//!
//! ## What this file is not
//!
//! **It reads nothing.** Opening the status line's file, tailing a Codex
//! rollout, subscribing to opencode's events -- that is the wiring, and it
//! is deliberately not here: it is where a wrong guess about somebody
//! else's file format costs days, and the plan says the formats are the
//! part to verify first. This is the plane underneath, where the arithmetic
//! is tested with bytes and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tasks = @import("Tasks.zig");
const TaskLog = @import("TaskLog.zig");
const quota = @import("quota.zig");

const log = std.log.scoped(.poltergeist);

/// Where a CLI's numbers arrive.
pub const Source = enum {
    /// A command the CLI runs as its status line, given a description of
    /// the session on stdin (Claude Code, and Antigravity's clone of it).
    statusline,
    /// A record the CLI writes for itself, one JSON object per line (Codex's
    /// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`).
    session_record,
    /// An event on the CLI's own bus, handed to Polter by that CLI's plugin
    /// (opencode's `session.usage.updated`).
    event,
};

/// What a reading is, which is what decides how two of them combine.
pub const Counts = enum {
    /// A total that only grows: what two readings differ by was spent in
    /// between.
    total,
    /// A level: how full the window is now. Over a stretch it is the level
    /// at the end of it, and two of them are never subtracted.
    window,
};

/// One CLI's declaration of where its token numbers are, as its
/// `plugin.json` gives it:
///
/// ```json
/// "token_says": {
///   "source": "session_record",
///   "counts": "total",
///   "keys": ["payload.info.total_token_usage.total_tokens"],
///   "at_key": "timestamp"
/// }
/// ```
///
/// `keys` are the numbers to add up, each a dotted path into the JSON that
/// CLI hands over; `at_key` is the path of the moment they were taken, left
/// out for a CLI that says no moment -- the reading is then stamped with the
/// moment it was read, which is the truth about it.
///
/// **Which session the numbers belong to is not declared**, because it comes
/// from the caller and not from the payload: a status line's input names its
/// session, and a Codex rollout line does not -- the session there is the
/// record the line was read out of, which only the reader knows.
pub const TokenSays = struct {
    source: Source,
    counts: Counts,
    keys: []const []const u8,
    at_key: ?[]const u8,

    /// The most fields one declaration may add up, and the most segments in
    /// one path: a bound because this comes off a file somebody else wrote.
    pub const max_keys = 8;
    pub const max_path_segments = 8;
    /// The longest one path may be.
    pub const max_path_bytes = 160;
};

/// Read a `token_says` section, or null for one that does not read.
///
/// **A section that does not read costs the section and not the plugin**,
/// as every other optional section does (`declined_says`, `title_says`): a
/// manifest is somebody else's file, a half-understood declaration would be
/// a number silently attributed by a rule nobody wrote, and the plugin may
/// well do its other jobs correctly. Every refusal is logged with the
/// plugin's key and the reason.
pub fn parse(arena: Allocator, key: []const u8, section: std.json.ObjectMap) Allocator.Error!?TokenSays {
    const source: Source = switch (section.get("source") orelse {
        log.warn("plugin {s}: token_says has no source; ignored", .{key});
        return null;
    }) {
        .string => |s| std.meta.stringToEnum(Source, s) orelse {
            log.warn("plugin {s}: token_says.source is \"{s}\", which is not statusline, session_record or event; ignored", .{ key, s });
            return null;
        },
        else => {
            log.warn("plugin {s}: token_says.source is not a string; ignored", .{key});
            return null;
        },
    };

    const counts: Counts = switch (section.get("counts") orelse {
        log.warn("plugin {s}: token_says has no counts; ignored", .{key});
        return null;
    }) {
        .string => |s| std.meta.stringToEnum(Counts, s) orelse {
            log.warn("plugin {s}: token_says.counts is \"{s}\", which is not total or window; ignored", .{ key, s });
            return null;
        },
        else => {
            log.warn("plugin {s}: token_says.counts is not a string; ignored", .{key});
            return null;
        },
    };

    const list = switch (section.get("keys") orelse {
        log.warn("plugin {s}: token_says has no keys; ignored", .{key});
        return null;
    }) {
        .array => |a| a.items,
        else => {
            log.warn("plugin {s}: token_says.keys is not a list; ignored", .{key});
            return null;
        },
    };
    if (list.len == 0 or list.len > TokenSays.max_keys) {
        log.warn("plugin {s}: token_says.keys has {d} entries, and 1 to {d} are read; ignored", .{ key, list.len, TokenSays.max_keys });
        return null;
    }
    const keys = try arena.alloc([]const u8, list.len);
    for (list, keys) |item, *o| {
        const path = switch (item) {
            .string => |s| s,
            else => {
                log.warn("plugin {s}: a token_says key that is not a string; ignored", .{key});
                return null;
            },
        };
        if (!validPath(path)) {
            log.warn("plugin {s}: token_says key \"{s}\" is not a dotted path; ignored", .{ key, path });
            return null;
        }
        o.* = path;
    }

    const at_key: ?[]const u8 = switch (section.get("at_key") orelse .null) {
        .null => null,
        .string => |s| if (validPath(s)) s else {
            log.warn("plugin {s}: token_says.at_key \"{s}\" is not a dotted path; ignored", .{ key, s });
            return null;
        },
        else => {
            log.warn("plugin {s}: token_says.at_key is not a string; ignored", .{key});
            return null;
        },
    };

    return .{ .source = source, .counts = counts, .keys = keys, .at_key = at_key };
}

/// A dotted path into a JSON object: one to `max_path_segments` segments,
/// none of them empty.
fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > TokenSays.max_path_bytes) return false;
    var segments: usize = 1;
    var previous_dot = true; // a path may not begin with one
    for (path) |c| {
        if (c == '.') {
            if (previous_dot) return false;
            previous_dot = true;
            segments += 1;
            if (segments > TokenSays.max_path_segments) return false;
        } else {
            previous_dot = false;
        }
    }
    return !previous_dot; // nor end with one
}

/// One moment's reading of one session.
pub const Reading = struct {
    /// The session, **spelled the way `Tasks.Span.session` is**
    /// (`<cli> <first 8 of the session id>`), so that the two can be joined
    /// at all. Made by `TaskLog.viaText` and nowhere else.
    session: []const u8,
    at_ms: i64,
    counts: Counts,
    tokens: u64,
};

/// A reading out of one JSON object the CLI handed over, or null when it
/// carries no numbers.
///
/// `at_ms` is what the reading is stamped with when the CLI's payload says
/// no moment (`declared.at_key`), and is ignored when it does say one:
/// taking the reader's clock over the writer's would put a reading in the
/// wrong stretch whenever the two disagree.
pub fn readingOf(
    arena: Allocator,
    cli: []const u8,
    session_id: []const u8,
    at_ms: i64,
    value: std.json.Value,
    declared: TokenSays,
) Allocator.Error!?Reading {
    var total: u64 = 0;
    for (declared.keys) |path| {
        const n = number(dig(value, path) orelse return null) orelse return null;
        if (!(n >= 0)) return null;
        total +|= @intFromFloat(@min(n, @as(f64, @floatFromInt(std.math.maxInt(u64) / TokenSays.max_keys))));
    }
    var at = at_ms;
    if (declared.at_key) |path| at = momentOf(dig(value, path) orelse return null) orelse return null;
    var buf: [96]u8 = undefined;
    return .{
        .session = try arena.dupe(u8, TaskLog.viaText(&buf, cli, session_id)),
        .at_ms = at,
        .counts = declared.counts,
        .tokens = total,
    };
}

/// A moment in a payload: either a wall-clock millisecond count or the
/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` Codex writes. Anything else is not a moment
/// this file will guess at.
fn momentOf(v: std.json.Value) ?i64 {
    if (number(v)) |n| {
        if (!(n >= 0)) return null;
        return @intFromFloat(@min(n, @as(f64, @floatFromInt(std.math.maxInt(i64)))));
    }
    return switch (v) {
        .string => |s| if (quota.isoMs(s)) |ms| @intCast(ms) else null,
        else => null,
    };
}

/// The value at a dotted path, or null when the path is not there or
/// something on the way is not an object.
fn dig(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        current = switch (current) {
            .object => |o| o.get(segment) orelse return null,
            else => return null,
        };
    }
    return current;
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// One stretch of a task, with what the readings say of it.
pub const Stretch = struct {
    /// Borrowed from the `Span` this was made from, which is the panel's.
    alias: []const u8,
    id: Tasks.Id,
    session: []const u8,
    from_ms: i64,
    /// The end of the stretch: the span's own, or the `now_ms` given to
    /// `attribute` for one still open.
    to_ms: i64,

    /// **Null is "no reading could say"**, and is never 0: a stretch whose
    /// session never reported, one that began after the last reading there
    /// is, one whose session named no place, and one whose total went down
    /// (a counter that was reset) all land here. A reader that shows only
    /// the sum is claiming more than was measured.
    tokens: ?u64,

    /// Which kind of number `tokens` is, and null with it.
    counts: ?Counts,

    /// The moment the reading `tokens` ends at was taken -- for a `window`
    /// count the level kept, for a `total` count the end of the interval.
    /// Null with `tokens == null`.
    read_at_ms: ?i64,

    /// For a `total` count, the moment the subtraction started from, which
    /// is what says how far back the number reaches: equal to `from_ms`
    /// when a reading landed there, earlier when the interval starts before
    /// the stretch does. Null when the session's own first reading is inside
    /// the stretch, so that it was added up from nothing.
    from_read_ms: ?i64,
};

/// What the readings say of each stretch of a task, in the order the spans
/// are in (oldest first, as `Tasks.spans` gives them).
///
/// **`now_ms` closes the open stretches**, and only those: a stretch whose
/// terminal still holds the place has no end of its own, and a number read
/// now is the newest one there is.
pub fn attribute(
    alloc: Allocator,
    spans: []const Tasks.Span,
    readings: []const Reading,
    now_ms: i64,
) Allocator.Error![]Stretch {
    const out = try alloc.alloc(Stretch, spans.len);
    for (spans, out) |sp, *o| {
        const to = if (sp.to_ms) |t| @max(t, sp.from_ms) else now_ms;
        o.* = .{
            .alias = sp.alias,
            .id = sp.id,
            .session = sp.session,
            .from_ms = sp.from_ms,
            .to_ms = to,
            .tokens = null,
            .counts = null,
            .read_at_ms = null,
            .from_read_ms = null,
        };
        // A stretch that names no session cannot be joined to any reading:
        // it is a place filled before its agent said who it was.
        if (sp.session.len == 0) continue;

        // The reading that says what the end of the stretch looked like.
        // One older than the stretch itself says nothing about it: the
        // session was not heard from while this place was held.
        const end = lastAt(readings, sp.session, to) orelse continue;
        if (end.at_ms < sp.from_ms) continue;

        switch (end.counts) {
            .window => {
                o.tokens = end.tokens;
                o.counts = .window;
                o.read_at_ms = end.at_ms;
            },
            .total => {
                // What it had spent when the stretch began: the newest
                // reading at or before `from_ms`, or nothing at all when
                // there is none -- the session's first reading is then
                // inside this stretch, so everything it has spent was spent
                // here.
                const base = lastAt(readings, sp.session, sp.from_ms);
                if (base) |b| {
                    // A declaration that changed under a running session is
                    // not something to subtract across either.
                    if (b.counts != .total) continue;
                    if (end.tokens < b.tokens) continue; // a counter that was reset
                    o.tokens = end.tokens - b.tokens;
                    o.from_read_ms = b.at_ms;
                } else {
                    o.tokens = end.tokens;
                }
                o.counts = .total;
                o.read_at_ms = end.at_ms;
            },
        }
    }
    return out;
}

/// One place's worth of the stretches, added up.
pub const Total = struct {
    alias: []const u8,
    id: Tasks.Id,
    /// Which kind of number `tokens` is, or null when no stretch of this
    /// place had one.
    counts: ?Counts,
    /// The sum of the stretches that had a number.
    tokens: u64,
    /// How many stretches had one.
    counted: usize,
    /// How many had none: the number above covers the rest of the task and
    /// not these.
    unknown: usize,
};

/// The stretches added up per place, in the order the places first appear.
///
/// **A level is never added to a level, and never to a total**: a sum of
/// levels over time is not a quantity, so where a place's stretches
/// disagree, the number is the first count's and the rest are `unknown`
/// rather than mixed in.
pub fn totals(alloc: Allocator, stretches: []const Stretch) Allocator.Error![]Total {
    var out: std.ArrayListUnmanaged(Total) = .empty;
    errdefer out.deinit(alloc);
    for (stretches) |st| {
        const at = for (out.items, 0..) |t, i| {
            if (t.id == st.id and std.mem.eql(u8, t.alias, st.alias)) break i;
        } else null;
        const tokens = st.tokens;
        const counts = st.counts;
        if (at) |i| {
            var t = &out.items[i];
            if (tokens) |n| {
                if (t.counts == null) {
                    t.counts = counts;
                    t.tokens = n;
                    t.counted = 1;
                } else if (t.counts == counts) {
                    t.tokens +|= n;
                    t.counted += 1;
                } else t.unknown += 1;
            } else t.unknown += 1;
        } else {
            try out.append(alloc, .{
                .alias = st.alias,
                .id = st.id,
                .counts = counts,
                .tokens = tokens orelse 0,
                .counted = if (tokens != null) 1 else 0,
                .unknown = if (tokens == null) 1 else 0,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The newest reading of `session` at or before `at`. Ties go to the last
/// one in the list, which is the one written last.
fn lastAt(readings: []const Reading, session: []const u8, at: i64) ?Reading {
    var best: ?Reading = null;
    for (readings) |r| {
        if (!std.mem.eql(u8, r.session, session)) continue;
        if (r.at_ms > at) continue;
        if (best == null or r.at_ms >= best.?.at_ms) best = r;
    }
    return best;
}

/// What a task's places have spent, readings and all: `Tasks.spans` for the
/// stretches, `attribute` for what each one is, `totals` for the places.
///
/// **This is the whole of "the core adds usage up per task"**, and it is
/// three calls because the three questions are separate: when the places
/// were held (`Tasks`, which owns that), what a number means (`attribute`),
/// and whose it is (`totals`). The readings come from the caller because
/// getting them is the wiring, and the wiring is not here.
///
/// The `Stretch` slice is the caller's to free; nothing else is allocated
/// beyond it and the totals.
pub fn taskTotals(
    alloc: Allocator,
    task: Tasks.Task,
    readings: []const Reading,
    now_ms: i64,
) Allocator.Error![]Total {
    const spans = try Tasks.spans(alloc, task);
    defer alloc.free(spans);
    const stretches = try attribute(alloc, spans, readings, now_ms);
    defer alloc.free(stretches);
    return totals(alloc, stretches);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn json(arena: Allocator, text: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch unreachable;
}

fn says(source: Source, counts: Counts, keys: []const []const u8, at_key: ?[]const u8) TokenSays {
    return .{ .source = source, .counts = counts, .keys = keys, .at_key = at_key };
}

/// Claude Code's status line input, cut down, with the four fields of
/// `current_usage` in it.
const claude_input =
    \\{"session_id":"002ae30e-0207-4450-9d52-5bbcc5840c1b",
    \\ "context_window":{"total_input_tokens":15234,"used_percentage":8,
    \\   "current_usage":{"input_tokens":19113,"output_tokens":250,
    \\     "cache_creation_input_tokens":100,"cache_read_input_tokens":40}}}
;

/// The declaration the Claude Code plugin ships.
const claude = says(.statusline, .window, &.{
    "context_window.current_usage.input_tokens",
    "context_window.current_usage.output_tokens",
    "context_window.current_usage.cache_creation_input_tokens",
    "context_window.current_usage.cache_read_input_tokens",
}, null);

/// Codex's, off its rollout lines.
const codex = says(.session_record, .total, &.{"payload.info.total_token_usage.total_tokens"}, "timestamp");

fn span(alias: []const u8, id: Tasks.Id, session: []const u8, from: i64, to: ?i64) Tasks.Span {
    return .{ .alias = alias, .id = id, .session = session, .from_ms = from, .to_ms = to };
}

test "usage: a declaration names the channel, the count and the fields; one that does not read costs only itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The three channels, read off a section as a manifest writes it.
    {
        const got = (try parse(a, "p", (json(a, "{\"source\":\"statusline\",\"counts\":\"window\",\"keys\":[\"a.b\"]}")).object)).?;
        try testing.expectEqual(Source.statusline, got.source);
        try testing.expectEqual(Counts.window, got.counts);
        try testing.expectEqualStrings("a.b", got.keys[0]);
        try testing.expectEqual(@as(?[]const u8, null), got.at_key);
    }
    {
        const got = (try parse(a, "p", (json(a, "{\"source\":\"session_record\",\"counts\":\"total\",\"keys\":[\"a\",\"b\"],\"at_key\":\"timestamp\"}")).object)).?;
        try testing.expectEqual(Source.session_record, got.source);
        try testing.expectEqualStrings("timestamp", got.at_key.?);
    }
    {
        const got = (try parse(a, "p", (json(a, "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"tokens\"]}")).object)).?;
        try testing.expectEqual(Source.event, got.source);
    }

    // Every way a section can fail to read. Each costs the section and
    // nothing else: a plugin whose token declaration is nonsense still does
    // its other jobs.
    const bad = [_][]const u8{
        "{}", // no source, no counts, no keys
        "{\"counts\":\"total\",\"keys\":[\"a\"]}", // no source
        "{\"source\":\"screen\",\"counts\":\"total\",\"keys\":[\"a\"]}", // a channel that is not one
        "{\"source\":3,\"counts\":\"total\",\"keys\":[\"a\"]}", // a channel that is not a word
        "{\"source\":\"event\",\"keys\":[\"a\"]}", // no counts
        "{\"source\":\"event\",\"counts\":\"counter\",\"keys\":[\"a\"]}", // not a kind of number
        "{\"source\":\"event\",\"counts\":true,\"keys\":[\"a\"]}", // not a word
        "{\"source\":\"event\",\"counts\":\"total\"}", // no fields
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[]}", // no fields
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":\"a\"}", // fields are not a list
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[1]}", // a field that is not a path
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"\"]}",
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a..b\"]}",
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a.\"]}",
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\".a\"]}",
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a.b.c.d.e.f.g.h.i\"]}", // one segment too deep
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}", // one field too many
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a\"],\"at_key\":3}", // a moment that is not a path
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a\"],\"at_key\":\"a.\"}",
        "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a\"],\"at_key\":\"\"}",
    };
    for (bad) |text| try testing.expect((try parse(a, "p", (json(a, text)).object)) == null);

    // A path of exactly the deepest allowed reads, so the bound above is
    // the bound and not one short of it.
    const deepest = "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a.b.c.d.e.f.g.h\"]}";
    try testing.expect((try parse(a, "p", (json(a, deepest)).object)) != null);
    // And a one-segment path, which is the shallowest there is.
    try testing.expect((try parse(a, "p", (json(a, "{\"source\":\"event\",\"counts\":\"total\",\"keys\":[\"a\"]}")).object)) != null);
}

test "usage: a reading adds the declared fields, and names the session the way the panel does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The four fields of `current_usage` add up, and a session id becomes
    // the panel's `<cli> <first 8>`, which is the only spelling a span can
    // be joined to (`TaskLog.viaText`).
    const got = (try readingOf(a, "claude-code", "002ae30e-0207-4450-9d52-5bbcc5840c1b", 1_700_000_000_000, json(a, claude_input), claude)).?;
    try testing.expectEqual(@as(u64, 19_503), got.tokens);
    try testing.expectEqual(Counts.window, got.counts);
    // No moment in the payload, so the reading is stamped with the reader's.
    try testing.expectEqual(@as(i64, 1_700_000_000_000), got.at_ms);
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(TaskLog.viaText(&buf, "claude-code", "002ae30e-0207-4450-9d52-5bbcc5840c1b"), got.session);
    try testing.expectEqualStrings("claude-code 002ae30e", got.session);

    // A payload with no numbers in it is not a reading of zero: the fields
    // are missing, which is a CLI saying nothing about its tokens.
    try testing.expect((try readingOf(a, "claude-code", "s", 1, json(a, "{\"session_id\":\"s\"}"), claude)) == null);
    // Before a session's first answer the object is there and null.
    try testing.expect((try readingOf(a, "claude-code", "s", 1, json(a, "{\"context_window\":{\"current_usage\":null}}"), claude)) == null);
    // **A partial sum is not a reading.** One field of four present, read as
    // the whole, is a number nobody measured -- and it would silently look
    // like a drop in the session's usage.
    try testing.expect((try readingOf(a, "claude-code", "s", 1, json(a, "{\"context_window\":{\"current_usage\":{\"input_tokens\":5}}}"), claude)) == null);
    // A negative field is not a count of anything.
    try testing.expect((try readingOf(a, "claude-code", "s", 1, json(a, "{\"context_window\":{\"current_usage\":{\"input_tokens\":-5,\"output_tokens\":1,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":1}}}"), claude)) == null);

    // Codex's rollout line: a total, and the moment comes out of the
    // payload rather than off the reader's clock.
    const codex_line =
        \\{"timestamp":"2026-10-24T13:30:48.093Z","type":"event_msg","payload":{"type":"token_count",
        \\ "info":{"total_token_usage":{"input_tokens":49384495,"output_tokens":460060,"total_tokens":49844555},
        \\         "last_token_usage":{"input_tokens":211056,"total_tokens":211981}}}}
    ;
    const got_codex = (try readingOf(a, "codex", "01a16e1a-c45f-79e2-94ec-59c43b3a2a35", 1, json(a, codex_line), codex)).?;
    try testing.expectEqual(@as(u64, 49_844_555), got_codex.tokens);
    try testing.expectEqual(Counts.total, got_codex.counts);
    // `quota.isoMs`, which this shares with the allowance reader, is whole
    // seconds: the `.093` Codex writes is dropped. That is the resolution
    // every reading has, and the reason `lastAt` breaks a tie towards the
    // reading written last rather than by moment alone.
    try testing.expectEqual(@as(i64, 1_792_848_648_000), got_codex.at_ms);
    // A line of the same record that is not the one carrying the numbers.
    try testing.expect((try readingOf(a, "codex", "s", 1, json(a, "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}"), codex)) == null);
    // **A moment that cannot be read refuses the reading** rather than
    // stamping it with the reader's clock: a reading put wherever the
    // reader happened to be standing is worse than none.
    try testing.expect((try readingOf(a, "codex", "s", 1, json(a, "{\"payload\":{\"info\":{\"total_token_usage\":{\"total_tokens\":7}}}}"), codex)) == null);
    try testing.expect((try readingOf(a, "codex", "s", 1, json(a, "{\"timestamp\":\"yesterday\",\"payload\":{\"info\":{\"total_token_usage\":{\"total_tokens\":7}}}}"), codex)) == null);
}

test "usage: a total is subtracted across a stretch, and a window is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One session, readings that only grow, three stretches end to end.
    const readings = [_]Reading{
        .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .total, .tokens = 40 },
        .{ .session = "codex aaaa1111", .at_ms = 200, .counts = .total, .tokens = 90 },
        .{ .session = "codex aaaa1111", .at_ms = 300, .counts = .total, .tokens = 150 },
        .{ .session = "codex aaaa1111", .at_ms = 400, .counts = .total, .tokens = 260 },
    };
    const spans = [_]Tasks.Span{
        span("开发", 0x11, "codex aaaa1111", 50, 200),
        span("开发", 0x11, "codex aaaa1111", 200, 300),
        span("开发", 0x11, "codex aaaa1111", 300, null),
    };
    const got = try attribute(a, &spans, &readings, 400);
    try testing.expectEqual(@as(usize, 3), got.len);
    // 50→200: no reading at or before 50, so the session's first reading is
    // inside the stretch -- it started from nothing, and everything it had
    // spent by 200 was spent here.
    try testing.expectEqual(@as(?u64, 90), got[0].tokens);
    try testing.expectEqual(@as(?i64, null), got[0].from_read_ms);
    try testing.expectEqual(@as(?i64, 200), got[0].read_at_ms);
    // 200→300 is 150-90, and 300→(still open, closed at the moment given)
    // is 260-150.
    try testing.expectEqual(@as(?u64, 60), got[1].tokens);
    try testing.expectEqual(Counts.total, got[1].counts.?);
    try testing.expectEqual(@as(?i64, 200), got[1].from_read_ms);
    try testing.expectEqual(@as(?u64, 110), got[2].tokens);
    try testing.expectEqual(@as(i64, 400), got[2].to_ms);
    // **The three add up to the session's whole spend**, which is the
    // property that makes the per-place sums worth showing.
    try testing.expectEqual(@as(u64, 260), got[0].tokens.? + got[1].tokens.? + got[2].tokens.?);

    // A window count is a level, not a spend: the stretch is what the
    // window held at the end of it, and two of them are never subtracted.
    {
        const win = [_]Reading{
            .{ .session = "claude-code bbbb2222", .at_ms = 100, .counts = .window, .tokens = 20_000 },
            .{ .session = "claude-code bbbb2222", .at_ms = 200, .counts = .window, .tokens = 60_000 },
        };
        const s = [_]Tasks.Span{span("审核", 0x33, "claude-code bbbb2222", 100, 200)};
        const one = try attribute(a, &s, &win, 300);
        try testing.expectEqual(Counts.window, one[0].counts.?);
        try testing.expectEqual(@as(?u64, 60_000), one[0].tokens);
        try testing.expectEqual(@as(?i64, 200), one[0].read_at_ms);
        // A window number is never "spent from nothing": it is a level.
        try testing.expectEqual(@as(?i64, null), one[0].from_read_ms);
    }

    // A session nobody ever reported: no number, and not zero.
    {
        const s = [_]Tasks.Span{span("开发", 0x11, "opencode cccc3333", 10, 20)};
        const one = try attribute(a, &s, &readings, 400);
        try testing.expectEqual(@as(?u64, null), one[0].tokens);
        try testing.expectEqual(@as(?Counts, null), one[0].counts);
    }

    // A stretch with no session named cannot be joined to anything: a place
    // filled before its agent said who it was (task 2470).
    {
        const s = [_]Tasks.Span{span("开发", 0x11, "", 10, 20)};
        const one = try attribute(a, &s, &readings, 400);
        try testing.expectEqual(@as(?u64, null), one[0].tokens);
    }

    // **A stretch nobody read during has no number**, even though readings
    // exist for that session on both sides of it: what it had spent inside
    // this stretch was never measured. `now` moves the last reading before
    // the stretch and nothing else.
    {
        const s = [_]Tasks.Span{span("开发", 0x11, "codex aaaa1111", 500, 600)};
        const one = try attribute(a, &s, &readings, 400);
        try testing.expectEqual(@as(?u64, null), one[0].tokens);
        try testing.expectEqual(@as(?i64, 600), one[0].to_ms);
    }

    // **A total that went down is a counter that was reset** -- a new
    // session under the same name, a CLI that restarted its count -- and
    // subtracting across it reports a number nobody spent. Null, and not
    // the difference.
    {
        const reset = [_]Reading{
            .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .total, .tokens = 900 },
            .{ .session = "codex aaaa1111", .at_ms = 200, .counts = .total, .tokens = 30 },
        };
        const s = [_]Tasks.Span{span("开发", 0x11, "codex aaaa1111", 100, 200)};
        const one = try attribute(a, &s, &reset, 400);
        try testing.expectEqual(@as(?u64, null), one[0].tokens);
    }

    // A declaration that changed under a running session is not subtracted
    // across either: a level and a spend are two kinds of number.
    {
        const mixed = [_]Reading{
            .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .window, .tokens = 5_000 },
            .{ .session = "codex aaaa1111", .at_ms = 200, .counts = .total, .tokens = 30 },
        };
        const s = [_]Tasks.Span{span("开发", 0x11, "codex aaaa1111", 100, 200)};
        const one = try attribute(a, &s, &mixed, 400);
        try testing.expectEqual(@as(?u64, null), one[0].tokens);
    }
}

test "usage: two sessions' readings never cross, and the stretches are answered one by one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const readings = [_]Reading{
        .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .total, .tokens = 10 },
        .{ .session = "claude-code bbbb2222", .at_ms = 120, .counts = .total, .tokens = 500 },
        .{ .session = "codex aaaa1111", .at_ms = 200, .counts = .total, .tokens = 45 },
        .{ .session = "claude-code bbbb2222", .at_ms = 260, .counts = .total, .tokens = 900 },
        .{ .session = "codex aaaa1111", .at_ms = 300, .counts = .total, .tokens = 60 },
    };
    // The same terminal held two different places, a second terminal held
    // one of them, and the spans are not in time order -- which the panel
    // does not promise either.
    const spans = [_]Tasks.Span{
        span("开发", 0x11, "codex aaaa1111", 200, 300),
        span("审核", 0x33, "claude-code bbbb2222", 100, 300),
        span("测试", 0x22, "codex aaaa1111", 100, 200),
    };
    const got = try attribute(a, &spans, &readings, 300);
    // Each stretch is its own session's readings, at its own boundaries.
    try testing.expectEqual(@as(?u64, 15), got[0].tokens); // 60-45
    // 审核's stretch begins at 100 and this session's first reading is at
    // 120, so the stretch holds the session's whole life: 900, not the
    // 900-500 that subtracting the *later* reading would give.
    try testing.expectEqual(@as(?u64, 900), got[1].tokens);
    try testing.expectEqual(@as(?i64, null), got[1].from_read_ms);
    try testing.expectEqual(@as(?u64, 35), got[2].tokens); // 45-10
    // A claude-code window reading and a codex total reading are not each
    // other's, and neither is used for the other's stretch.
    try testing.expect(!std.mem.eql(u8, got[0].session, got[1].session));

    // Added up per place: the two stretches with different aliases stay two
    // rows even though one terminal held both.
    const rows = try totals(a, got);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("开发", rows[0].alias);
    try testing.expectEqual(@as(u64, 15), rows[0].tokens);
    try testing.expectEqual(@as(usize, 1), rows[0].counted);
    try testing.expectEqual(@as(usize, 0), rows[0].unknown);
    try testing.expectEqual(@as(Tasks.Id, 0x11), rows[0].id);
    try testing.expectEqualStrings("测试", rows[2].alias);
    try testing.expectEqual(@as(u64, 35), rows[2].tokens);
    // The same terminal, two places, and the numbers are the places'.
    try testing.expectEqual(@as(Tasks.Id, 0x22), rows[2].id);
}

test "usage: a place's stretches add up, and the ones with no reading are counted as unknown rather than as zero" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const readings = [_]Reading{
        .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .total, .tokens = 0 },
        .{ .session = "codex aaaa1111", .at_ms = 200, .counts = .total, .tokens = 70 },
        .{ .session = "codex aaaa1111", .at_ms = 300, .counts = .total, .tokens = 100 },
    };
    const spans = [_]Tasks.Span{
        span("开发", 0x11, "codex aaaa1111", 100, 200),
        // The same place again, later, under a session nothing was heard
        // from: the sum covers the other two and not this one.
        span("开发", 0x11, "codex ffff9999", 400, 500),
        span("开发", 0x11, "codex aaaa1111", 200, 300),
    };
    const got = try attribute(a, &spans, &readings, 600);
    const rows = try totals(a, got);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u64, 100), rows[0].tokens); // 70 + 30
    try testing.expectEqual(@as(usize, 2), rows[0].counted);
    try testing.expectEqual(Counts.total, rows[0].counts.?);
    // **The stretch nobody reported is not 0 in the sum.** It is said
    // separately, so a reader shows "100 over two of three stretches" and
    // never "100" over a task the number does not cover.
    try testing.expectEqual(@as(usize, 1), rows[0].unknown);

    // A place with a level and a spend in it: they are never added, and the
    // one that does not match the place's count is unknown rather than
    // mixed in.
    {
        const mixed = [_]Stretch{
            .{ .alias = "审核", .id = 0x33, .session = "s", .from_ms = 0, .to_ms = 1, .tokens = 10, .counts = .total, .read_at_ms = 1, .from_read_ms = 0 },
            .{ .alias = "审核", .id = 0x33, .session = "s", .from_ms = 1, .to_ms = 2, .tokens = 9_000, .counts = .window, .read_at_ms = 2, .from_read_ms = null },
        };
        const rows2 = try totals(a, &mixed);
        try testing.expectEqual(@as(usize, 1), rows2.len);
        try testing.expectEqual(@as(u64, 10), rows2[0].tokens);
        try testing.expectEqual(Counts.total, rows2[0].counts.?);
        try testing.expectEqual(@as(usize, 1), rows2[0].counted);
        try testing.expectEqual(@as(usize, 1), rows2[0].unknown);
    }

    // A place no stretch of which had a number: the row is there, with a
    // count of zero stretches and an empty sum, and every stretch unknown.
    {
        const none = [_]Stretch{
            .{ .alias = "测试", .id = 0x22, .session = "s", .from_ms = 0, .to_ms = 1, .tokens = null, .counts = null, .read_at_ms = null, .from_read_ms = null },
        };
        const rows3 = try totals(a, &none);
        try testing.expectEqual(@as(usize, 1), rows3.len);
        try testing.expectEqual(@as(?Counts, null), rows3[0].counts);
        try testing.expectEqual(@as(usize, 0), rows3[0].counted);
        try testing.expectEqual(@as(usize, 1), rows3[0].unknown);
        try testing.expectEqual(@as(u64, 0), rows3[0].tokens);
    }

    // No stretches at all is no rows, not one empty row.
    try testing.expectEqual(@as(usize, 0), (try totals(a, &.{})).len);
}

test "usage: a task's panel, joined and left, adds up through the same path the product uses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real panel, two places taken and one given up, so the spans come
    // out of `Tasks` rather than being written by hand here: the join
    // between a span's session string and a reading's is the thing that
    // would rot silently, and it is only exercised by going through the
    // panel that writes it.
    var panel = Tasks.init(testing.allocator, .{});
    defer panel.deinit();
    const id = try panel.create("build", "ship it", .other);
    try panel.join(id, "开发", "worker-dev", 0x11, "codex aaaa1111", 100, true);
    try panel.join(id, "审核", "worker-review", 0x22, "claude-code bbbb2222", 150, false);
    try panel.leave(id, "审核", 300);

    const readings = [_]Reading{
        .{ .session = "codex aaaa1111", .at_ms = 100, .counts = .total, .tokens = 1_000 },
        .{ .session = "codex aaaa1111", .at_ms = 400, .counts = .total, .tokens = 2_500 },
        // A level, for the other CLI: 审核's place is what the window held
        // when it let go, and is not a spend at all.
        .{ .session = "claude-code bbbb2222", .at_ms = 150, .counts = .window, .tokens = 40_000 },
        .{ .session = "claude-code bbbb2222", .at_ms = 300, .counts = .window, .tokens = 90_000 },
    };

    const rows = try taskTotals(a, panel.get(id).?, &readings, 400);
    try testing.expectEqual(@as(usize, 2), rows.len);

    try testing.expectEqualStrings("开发", rows[0].alias);
    try testing.expectEqual(@as(Tasks.Id, 0x11), rows[0].id);
    try testing.expectEqual(Counts.total, rows[0].counts.?);
    try testing.expectEqual(@as(u64, 1_500), rows[0].tokens); // 2500-1000, the open stretch closed at 400
    try testing.expectEqual(@as(usize, 1), rows[0].counted);
    try testing.expectEqual(@as(usize, 0), rows[0].unknown);

    try testing.expectEqualStrings("审核", rows[1].alias);
    try testing.expectEqual(Counts.window, rows[1].counts.?);
    // The level at the moment the place was given up -- 300 -- and not the
    // 40_000 it was at when it took the place.
    try testing.expectEqual(@as(u64, 90_000), rows[1].tokens);
    try testing.expectEqual(@as(usize, 1), rows[1].counted);
    try testing.expectEqual(@as(usize, 0), rows[1].unknown);

    // **A task with no place ever filled** reads as one place with no alias
    // and no readings -- `Tasks.membersOf`'s implicit member -- and every
    // stretch of it is unknown. Not a panic, and not an empty reply.
    {
        const solo = try panel.create("build", "alone", .other);
        try panel.assign(solo, 0x33);
        const one = try taskTotals(a, panel.get(solo).?, &readings, 400);
        // A task with no squad has no spans at all, so no rows: the usage of
        // a single-terminal task is not attributed to a place, because
        // nothing recorded when it held one.
        try testing.expectEqual(@as(usize, 0), one.len);
    }
}
