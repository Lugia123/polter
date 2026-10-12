//! How much of each subscription's allowance is used: the block at the
//! bottom of the control room's list (dev-docs/poltergeist/control-room.md,
//! 3.6).
//!
//! Every agent on one account draws on one allowance, and when it runs out
//! every group stops at once. This says so before it happens. **One row is
//! one account, not one agent.**
//!
//! Like everything else in a snapshot, **all of it is decided here**: which
//! account is opened out and which is a number in the one line, whether a
//! number is old, whether its window has already come round again, whether
//! the way out is named. A host draws what it is given and formats two
//! things only, a count ("40 分钟后恢复") and a moment ("13:40").
//!
//! ```
//! "quota": {
//!   "near_percent": 80,
//!   "alerts": [ {             an account at or past the line: opened out
//!       "family": "claude",   claude | codex
//!       "level": "near",      near | out (out: 100, with the triangle)
//!       "span": "five_hour",  which window: five_hour | seven_day | month |
//!                             other
//!       "used": 92,
//!       "resets_ms": 1700000000000,     wall
//!       "when": {"form":"minutes","n":40},
//!                             how the moment is said. minutes | hours | days:
//!                             "n … from now". clock: the time of day of
//!                             resets_ms. date: its day and time of day
//!       "stale": {"unit":"hours","n":3} | null,
//!                             set when the number is old
//!       "way_out": "codex" | null,
//!                             on `out` only: an account that has room
//!       "at_ms": 1700000000000,         wall: when the numbers were taken.
//!                                       Not compared
//!       "windows": [ {"span":"five_hour","used":92,"live":true,
//!                     "resets_ms":1700000000000} ] } ],
//!                             every window of the account, for a tooltip.
//!                             live: false once its reset has passed
//!   "line": {                 the one line; null when every account is
//!                             opened out
//!       "label": "used",      used | none_yet (no number from anybody, and
//!                             then entries is empty)
//!       "entries": [ {
//!           "family": "codex",
//!           "state": "fresh", fresh | stale | recovered | unreadable
//!           "used": 20 | null,          null when recovered or unreadable
//!           "span": "five_hour" | null, the window `used` is of: the one
//!                                       used most
//!           "stale": {"unit":"hours","n":3} | null,
//!           "at_ms": 1700000000000 | null,
//!           "windows": [ … ] } ] } }
//! ```
//!
//! An account that pays by the token has no window and is not here at all.
//! A CLI nothing can be read from (Gemini, opencode, …) is not here either;
//! `unreadable` is for the two that should have had a number and did not.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where "close to the limit" begins. 暂定: nothing says 80 is the right
/// number. This is the one place it is written.
pub const near_percent: u8 = 80;

/// How old a number is before it is said to be old. 暂定.
pub const stale_after_ms: u64 = 60 * min;

const min: u64 = std.time.ms_per_min;
const hour: u64 = std.time.ms_per_hour;
const day: u64 = std.time.ms_per_day;

/// Whose allowance. The order here is the order they are drawn in.
pub const Family = enum { claude, codex };

/// Which window of an allowance.
pub const Span = enum {
    five_hour,
    seven_day,
    /// A free Codex account's only window.
    month,
    other,

    pub fn ofMinutes(minutes: u64) Span {
        return switch (minutes) {
            300 => .five_hour,
            10080 => .seven_day,
            43200 => .month,
            else => .other,
        };
    }
};

pub const Window = struct {
    span: Span,
    /// Whole percent, rounded down: 100 only when it is all gone.
    used: u8,
    /// Wall clock.
    resets_ms: u64,
};

/// At most this many windows to an account.
pub const max_windows = 2;

/// What was last read for one account.
pub const Reading = struct {
    family: Family,
    state: State,
    windows: [max_windows]?Window,
    /// Wall clock: when the numbers were taken.
    at_ms: u64,

    pub const State = enum {
        have,
        /// There should have been a number and it could not be read. Not
        /// the same as never having had one, which is no `Reading` at all.
        unreadable,
    };

    pub fn unreadable(family: Family, at_ms: u64) Reading {
        return .{ .family = family, .state = .unreadable, .windows = @splat(null), .at_ms = at_ms };
    }

    pub fn eql(a: Reading, b: Reading) bool {
        return std.meta.eql(a, b);
    }
};

// -- what comes out ---------------------------------------------------------

pub const Ago = struct {
    unit: enum { hours, days },
    n: u32,
};

pub const When = struct {
    form: Form,
    /// The count for minutes, hours and days; zero for the other two.
    n: u32,

    pub const Form = enum { minutes, hours, days, clock, date };
};

pub const WindowOut = struct {
    span: Span,
    used: u8,
    live: bool,
    resets_ms: u64,
};

pub const Alert = struct {
    family: Family,
    level: Level,
    span: Span,
    used: u8,
    resets_ms: u64,
    when: When,
    stale: ?Ago,
    way_out: ?Family,
    at_ms: u64,
    windows: []const WindowOut,

    pub const Level = enum { near, out };
};

pub const Entry = struct {
    family: Family,
    state: State,
    used: ?u8,
    span: ?Span,
    stale: ?Ago,
    at_ms: ?u64,
    windows: []const WindowOut,

    pub const State = enum {
        fresh,
        /// The number is old; it is still the last one there is.
        stale,
        /// Every window it was a number of has come round again. What is
        /// used now is not known, and is not the old number.
        recovered,
        unreadable,
    };
};

pub const Line = struct {
    label: Label,
    entries: []const Entry,

    pub const Label = enum { used, none_yet };
};

pub const Out = struct {
    near_percent: u8,
    alerts: []const Alert,
    line: ?Line,

    /// What a control room with no number from anybody shows.
    pub const none_yet: Out = .{
        .near_percent = near_percent,
        .alerts = &.{},
        .line = .{ .label = .none_yet, .entries = &.{} },
    };
};

pub const Built = struct {
    out: Out,
    /// The next moment, on the wall clock, at which this would come out
    /// different with the same readings. Null: never.
    wake_ms: ?u64,
};

// -- working it out ---------------------------------------------------------

fn sooner(a: ?u64, b: u64, now_ms: u64) ?u64 {
    if (b <= now_ms) return a;
    return if (a) |x| @min(x, b) else b;
}

fn agoOf(age_ms: u64) ?Ago {
    if (age_ms < stale_after_ms) return null;
    if (age_ms < 2 * day) return .{ .unit = .hours, .n = @intCast(@max(1, age_ms / hour)) };
    return .{ .unit = .days, .n = @intCast(age_ms / day) };
}

/// When what `agoOf` says next changes.
fn agoChanges(at_ms: u64, age_ms: u64) u64 {
    if (age_ms < stale_after_ms) return at_ms +| stale_after_ms;
    if (age_ms < 2 * day) return at_ms +| (age_ms / hour + 1) * hour;
    return at_ms +| (age_ms / day + 1) * day;
}

const Said = struct { when: When, changes_ms: ?u64 };

/// How a reset `left_ms` away is said, and when that next reads differently.
/// Close to the limit it is how long from now, which is what decides
/// whether to wait; once it is all gone it is the moment itself.
fn whenOf(level: Alert.Level, resets_ms: u64, left_ms: u64) Said {
    switch (level) {
        .out => {
            if (left_ms <= day) return .{ .when = .{ .form = .clock, .n = 0 }, .changes_ms = null };
            return .{ .when = .{ .form = .date, .n = 0 }, .changes_ms = resets_ms - day };
        },
        .near => {
            if (left_ms <= 90 * min) {
                // Never less than one: a reset that is not ahead is not said
                // at all, and nothing here should depend on the caller
                // having seen to that.
                const n = @max(1, (left_ms + min - 1) / min);
                return .{
                    .when = .{ .form = .minutes, .n = @intCast(n) },
                    .changes_ms = resets_ms - (n - 1) * min,
                };
            }
            if (left_ms <= 2 * day) {
                const n = (left_ms + 30 * min - 1) / hour;
                return .{
                    .when = .{ .form = .hours, .n = @intCast(n) },
                    .changes_ms = resets_ms - @max(n * hour - 30 * min, 90 * min),
                };
            }
            const n = (left_ms + 12 * hour - 1) / day;
            return .{
                .when = .{ .form = .days, .n = @intCast(n) },
                .changes_ms = resets_ms - @max(n * day - 12 * hour, 2 * day),
            };
        },
    }
}

/// The block, from what was last read for each account, as of `now_ms` on
/// the wall clock. At most one reading to a family; a later one for the
/// same family replaces an earlier. Everything in the result is `arena`'s.
pub fn build(arena: Allocator, readings: []const Reading, now_ms: u64) Allocator.Error!Built {
    var alerts: std.ArrayListUnmanaged(Alert) = .empty;
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var wake: ?u64 = null;

    for (std.enums.values(Family)) |family| {
        const r = blk: {
            var found: ?Reading = null;
            for (readings) |x| if (x.family == family) {
                found = x;
            };
            break :blk found orelse continue;
        };

        if (r.state == .unreadable) {
            try entries.append(arena, .{
                .family = family,
                .state = .unreadable,
                .used = null,
                .span = null,
                .stale = null,
                .at_ms = null,
                .windows = &.{},
            });
            continue;
        }

        var windows: std.ArrayListUnmanaged(WindowOut) = .empty;
        var worst: ?Window = null;
        for (r.windows) |maybe| {
            const w = maybe orelse continue;
            const live = w.resets_ms > now_ms;
            try windows.append(arena, .{ .span = w.span, .used = w.used, .live = live, .resets_ms = w.resets_ms });
            if (!live) continue;
            wake = sooner(wake, w.resets_ms, now_ms);
            if (worst) |b| {
                if (w.used < b.used) continue;
                if (w.used == b.used and w.resets_ms <= b.resets_ms) continue;
            }
            worst = w;
        }
        // An account with no window is one that pays by the token.
        if (windows.items.len == 0) continue;

        const top = worst orelse {
            try entries.append(arena, .{
                .family = family,
                .state = .recovered,
                .used = null,
                .span = null,
                .stale = null,
                .at_ms = r.at_ms,
                .windows = windows.items,
            });
            continue;
        };

        const age = now_ms -| r.at_ms;
        const ago = agoOf(age);
        wake = sooner(wake, agoChanges(r.at_ms, age), now_ms);

        if (top.used < near_percent) {
            try entries.append(arena, .{
                .family = family,
                .state = if (ago == null) .fresh else .stale,
                .used = top.used,
                .span = top.span,
                .stale = ago,
                .at_ms = r.at_ms,
                .windows = windows.items,
            });
            continue;
        }

        const level: Alert.Level = if (top.used >= 100) .out else .near;
        const said = whenOf(level, top.resets_ms, top.resets_ms -| now_ms);
        if (said.changes_ms) |at| wake = sooner(wake, at, now_ms);
        try alerts.append(arena, .{
            .family = family,
            .level = level,
            .span = top.span,
            .used = top.used,
            .resets_ms = top.resets_ms,
            .when = said.when,
            .stale = ago,
            .way_out = null,
            .at_ms = r.at_ms,
            .windows = windows.items,
        });
    }

    // The way out is named only when it is one: a number that is not old,
    // of an account that is not itself close.
    for (alerts.items) |*a| {
        if (a.level != .out) continue;
        for (entries.items) |e| {
            if (e.state != .fresh) continue;
            a.way_out = e.family;
            break;
        }
    }

    const line: ?Line = if (entries.items.len > 0)
        .{ .label = .used, .entries = entries.items }
    else if (alerts.items.len == 0)
        Out.none_yet.line
    else
        null;

    return .{
        .out = .{ .near_percent = near_percent, .alerts = alerts.items, .line = line },
        .wake_ms = wake,
    };
}

/// `out` with what moves on its own taken out, for telling two apart.
pub fn stripped(arena: Allocator, out: Out) Allocator.Error!Out {
    var s = out;
    const alerts = try arena.dupe(Alert, out.alerts);
    for (alerts) |*a| a.at_ms = 0;
    s.alerts = alerts;
    if (out.line) |line| {
        const entries = try arena.dupe(Entry, line.entries);
        for (entries) |*e| if (e.at_ms != null) {
            e.at_ms = 0;
        };
        s.line = .{ .label = line.label, .entries = entries };
    }
    return s;
}

// -- reading what the CLIs say ----------------------------------------------

fn number(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn object(v: ?std.json.Value) ?std.json.ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn percent(x: f64) ?u8 {
    if (!(x >= 0)) return null;
    return @intFromFloat(@floor(@min(x, 100)));
}

fn seconds(x: f64) ?u64 {
    if (!(x > 0) or x > 1e11) return null;
    return @as(u64, @intFromFloat(x)) * std.time.ms_per_s;
}

fn windowOf(span: Span, o: std.json.ObjectMap, used_key: []const u8) ?Window {
    return .{
        .span = span,
        .used = percent(number(o.get(used_key)) orelse return null) orelse return null,
        .resets_ms = seconds(number(o.get("resets_at")) orelse return null) orelse return null,
    };
}

/// The windows in what Claude Code hands a status line command on stdin:
/// `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`, a
/// percentage and Unix seconds (measured on 2.1.296; absent until the
/// session's first answer, and for an account that pays by the token).
/// Null when there are none.
pub fn fromClaudeStatus(arena: Allocator, stdin: []const u8) ?[max_windows]?Window {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, stdin, .{}) catch return null;
    const limits = object((object(root) orelse return null).get("rate_limits")) orelse return null;
    var out: [max_windows]?Window = @splat(null);
    if (object(limits.get("five_hour"))) |o| out[0] = windowOf(.five_hour, o, "used_percentage");
    if (object(limits.get("seven_day"))) |o| out[1] = windowOf(.seven_day, o, "used_percentage");
    if (out[0] == null and out[1] == null) return null;
    return out;
}

/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` as Unix milliseconds.
fn isoMs(s: []const u8) ?u64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    if (s[s.len - 1] != 'Z') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (y < 1970 or m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60) return null;

    // Days since 1970-01-01 of a civil date (the usual era arithmetic).
    const yy = y - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * @mod(m + 9, 12) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return @intCast((days * 86400 + hh * 3600 + mm * 60 + ss) * 1000);
}

pub const CodexLine = struct {
    windows: [max_windows]?Window,
    at_ms: u64,
};

/// One line of a Codex session record, when it is the one that carries the
/// allowance: `{"timestamp":…,"type":"event_msg","payload":{"type":
/// "token_count","rate_limits":{"primary":{"used_percent":…,
/// "window_minutes":…,"resets_at":…},"secondary":…|null}}}` (measured on
/// records written by codex-cli 0.142). Null for every other line, and for
/// one whose windows are both null -- an account that pays by the token.
pub fn fromCodexLine(arena: Allocator, line: []const u8) ?CodexLine {
    // Most lines are something else, and some are very long.
    if (std.mem.indexOf(u8, line, "\"token_count\"") == null) return null;
    const root = object(std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null) orelse return null;
    const payload = object(root.get("payload")) orelse return null;
    const kind = payload.get("type") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "token_count")) return null;
    const limits = object(payload.get("rate_limits")) orelse return null;
    const stamp = root.get("timestamp") orelse return null;
    if (stamp != .string) return null;

    var out: CodexLine = .{ .windows = @splat(null), .at_ms = isoMs(stamp.string) orelse return null };
    for ([_][]const u8{ "primary", "secondary" }, 0..) |key, i| {
        const o = object(limits.get(key)) orelse continue;
        const minutes = number(o.get("window_minutes")) orelse continue;
        if (!(minutes > 0)) continue;
        out.windows[i] = windowOf(.ofMinutes(@intFromFloat(minutes)), o, "used_percent");
    }
    if (out.windows[0] == null and out.windows[1] == null) return null;
    return out;
}

/// What `polter +statusline` leaves for the app to read: the windows, and
/// when they were taken.
pub const Drop = struct {
    v: u32,
    at_ms: u64,
    windows: []const Window,

    pub const version = 1;
};

pub fn writeDrop(w: *std.Io.Writer, windows: [max_windows]?Window, at_ms: u64) std.Io.Writer.Error!void {
    var list: [max_windows]Window = undefined;
    var n: usize = 0;
    for (windows) |maybe| if (maybe) |x| {
        list[n] = x;
        n += 1;
    };
    const drop: Drop = .{ .v = Drop.version, .at_ms = at_ms, .windows = list[0..n] };
    try std.json.Stringify.value(drop, .{}, w);
    try w.writeByte('\n');
}

/// Null when the bytes are not a drop this version wrote.
pub fn readDrop(arena: Allocator, family: Family, bytes: []const u8) ?Reading {
    const drop = std.json.parseFromSliceLeaky(Drop, arena, bytes, .{}) catch return null;
    if (drop.v != Drop.version or drop.windows.len > max_windows) return null;
    var out: Reading = .{ .family = family, .state = .have, .windows = @splat(null), .at_ms = drop.at_ms };
    for (drop.windows, 0..) |w, i| {
        if (w.used > 100) return null;
        out.windows[i] = w;
    }
    return out;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Noon, somewhere.
const noon: u64 = 1_700_000_000_000;

fn have(family: Family, short: ?Window, long: ?Window, at_ms: u64) Reading {
    return .{ .family = family, .state = .have, .windows = .{ short, long }, .at_ms = at_ms };
}

fn win(span: Span, used: u8, left_ms: u64) Window {
    return .{ .span = span, .used = used, .resets_ms = noon + left_ms };
}

fn built(arena: Allocator, readings: []const Reading) !Out {
    return (try build(arena, readings, noon)).out;
}

test "quota: an ordinary day is one line, each account by the window it has used most" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 61, 2 * hour), win(.seven_day, 12, 3 * day), noon - min),
        have(.codex, win(.five_hour, 9, hour), win(.seven_day, 20, 5 * day), noon - 2 * min),
    });

    const alerts = out.alerts.len;
    try testing.expectEqual(@as(usize, 0), alerts);
    const line = out.line.?;
    const label = line.label;
    try testing.expectEqual(Line.Label.used, label);
    try testing.expectEqual(@as(usize, 2), line.entries.len);

    const claude = line.entries[0];
    try testing.expectEqual(Family.claude, claude.family);
    const claude_state = claude.state;
    try testing.expectEqual(Entry.State.fresh, claude_state);
    const claude_used = claude.used;
    try testing.expectEqual(@as(?u8, 61), claude_used);
    try testing.expectEqual(@as(?Span, .five_hour), claude.span);

    const codex = line.entries[1];
    const codex_used = codex.used;
    try testing.expectEqual(@as(?u8, 20), codex_used);
    const codex_span = codex.span;
    try testing.expectEqual(@as(?Span, .seven_day), codex_span);
    // Both windows are there for whoever asks which one that was.
    try testing.expectEqual(@as(usize, 2), codex.windows.len);
}

test "quota: past the line an account is opened out, and says how long until it comes back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 92, 40 * min), win(.seven_day, 30, 3 * day), noon - min),
        have(.codex, win(.five_hour, 20, hour), null, noon - min),
    });

    try testing.expectEqual(@as(usize, 1), out.alerts.len);
    const a = out.alerts[0];
    const level = a.level;
    try testing.expectEqual(Alert.Level.near, level);
    try testing.expectEqual(Family.claude, a.family);
    try testing.expectEqual(Span.five_hour, a.span);
    try testing.expectEqual(@as(u8, 92), a.used);
    const when = a.when;
    try testing.expectEqual(When{ .form = .minutes, .n = 40 }, when);
    // Nothing has run out, so there is nowhere to send anybody.
    const way_out = a.way_out;
    try testing.expectEqual(@as(?Family, null), way_out);

    // The other account stays in the line, and the opened one leaves it.
    const entries = out.line.?.entries;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(Family.codex, entries[0].family);
}

test "quota: the line is at eighty, and seventy-nine is an ordinary day" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u8, 80), near_percent);
    const under = try built(arena.allocator(), &.{have(.claude, win(.five_hour, 79, hour), null, noon)});
    const under_alerts = under.alerts.len;
    try testing.expectEqual(@as(usize, 0), under_alerts);
    const at = try built(arena.allocator(), &.{have(.claude, win(.five_hour, 80, hour), null, noon)});
    const at_alerts = at.alerts.len;
    try testing.expectEqual(@as(usize, 1), at_alerts);
    // With its only account opened out, there is no line left to draw.
    const at_line = at.line;
    try testing.expectEqual(@as(?Line, null), at_line);
}

test "quota: used up, with room on the other account: the moment it comes back, and the way out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 100, 100 * min), win(.seven_day, 64, 3 * day), noon - min),
        have(.codex, win(.five_hour, 20, hour), null, noon - min),
    });

    const a = out.alerts[0];
    const level = a.level;
    try testing.expectEqual(Alert.Level.out, level);
    const form = a.when.form;
    try testing.expectEqual(When.Form.clock, form);
    try testing.expectEqual(noon + 100 * min, a.resets_ms);
    const way_out = a.way_out;
    try testing.expectEqual(@as(?Family, .codex), way_out);
}

test "quota: used up, and the other account close too: no way out is named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 100, 100 * min), null, noon - min),
        have(.codex, win(.five_hour, 85, hour), null, noon - min),
    });

    try testing.expectEqual(@as(usize, 2), out.alerts.len);
    const claude = out.alerts[0];
    const claude_level = claude.level;
    try testing.expectEqual(Alert.Level.out, claude_level);
    const way_out = claude.way_out;
    try testing.expectEqual(@as(?Family, null), way_out);
    const codex_level = out.alerts[1].level;
    try testing.expectEqual(Alert.Level.near, codex_level);
    const line = out.line;
    try testing.expectEqual(@as(?Line, null), line);
}

test "quota: an old number says how old, and is nobody's way out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 100, 100 * min), null, noon - min),
        have(.codex, null, win(.seven_day, 20, 3 * day), noon - 3 * hour - 5 * min),
    });

    const codex = out.line.?.entries[0];
    const state = codex.state;
    try testing.expectEqual(Entry.State.stale, state);
    const stale = codex.stale;
    try testing.expectEqual(@as(?Ago, .{ .unit = .hours, .n = 3 }), stale);
    // Still the last number there is.
    try testing.expectEqual(@as(?u8, 20), codex.used);
    const way_out = out.alerts[0].way_out;
    try testing.expectEqual(@as(?Family, null), way_out);
}

test "quota: a number is old from an hour, and in days from two" {
    const just_under = agoOf(stale_after_ms - 1);
    try testing.expectEqual(@as(?Ago, null), just_under);
    const at = agoOf(stale_after_ms);
    try testing.expectEqual(@as(?Ago, .{ .unit = .hours, .n = 1 }), at);
    try testing.expectEqual(@as(?Ago, .{ .unit = .hours, .n = 47 }), agoOf(2 * day - 1));
    const days = agoOf(2 * day);
    try testing.expectEqual(@as(?Ago, .{ .unit = .days, .n = 2 }), days);
}

test "quota: a window that has come round again is not its old number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const past: Window = .{ .span = .five_hour, .used = 97, .resets_ms = noon - min };
    const out = try built(arena.allocator(), &.{
        .{ .family = .claude, .state = .have, .windows = .{ past, null }, .at_ms = noon - 6 * hour },
    });

    // Ninety-seven of a window that is over opens nothing out.
    const alerts = out.alerts.len;
    try testing.expectEqual(@as(usize, 0), alerts);
    const e = out.line.?.entries[0];
    const state = e.state;
    try testing.expectEqual(Entry.State.recovered, state);
    const used = e.used;
    try testing.expectEqual(@as(?u8, null), used);
    const live = e.windows[0].live;
    try testing.expect(!live);
}

test "quota: with one window over, the account is the other one's number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const past: Window = .{ .span = .five_hour, .used = 97, .resets_ms = noon - min };
    const out = try built(arena.allocator(), &.{
        .{ .family = .claude, .state = .have, .windows = .{ past, win(.seven_day, 41, 2 * day) }, .at_ms = noon - 10 * min },
    });
    const e = out.line.?.entries[0];
    const used = e.used;
    try testing.expectEqual(@as(?u8, 41), used);
    try testing.expectEqual(@as(?Span, .seven_day), e.span);
}

test "quota: an account that could not be read says so, and is not a zero" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{
        have(.claude, win(.five_hour, 100, 100 * min), null, noon - min),
        Reading.unreadable(.codex, noon),
    });

    const e = out.line.?.entries[0];
    try testing.expectEqual(Family.codex, e.family);
    const state = e.state;
    try testing.expectEqual(Entry.State.unreadable, state);
    const used = e.used;
    try testing.expectEqual(@as(?u8, null), used);
    // And an account nothing is known about is not somewhere to go.
    const way_out = out.alerts[0].way_out;
    try testing.expectEqual(@as(?Family, null), way_out);
}

test "quota: with no number from anybody it says there is none yet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try build(arena.allocator(), &.{}, noon);
    const line = b.out.line.?;
    const label = line.label;
    try testing.expectEqual(Line.Label.none_yet, label);
    const entries = line.entries.len;
    try testing.expectEqual(@as(usize, 0), entries);
    try testing.expectEqual(@as(usize, 0), b.out.alerts.len);
    // And nothing will change that on its own.
    const wake = b.wake_ms;
    try testing.expectEqual(@as(?u64, null), wake);
}

test "quota: an account with no window pays by the token, and is not there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try built(arena.allocator(), &.{have(.claude, null, null, noon)});
    const label = out.line.?.label;
    try testing.expectEqual(Line.Label.none_yet, label);
}

test "quota when: minutes to ninety, then hours, then days; the moment once it is gone" {
    const m40 = whenOf(.near, noon + 40 * min, 40 * min).when;
    try testing.expectEqual(When{ .form = .minutes, .n = 40 }, m40);
    const part = whenOf(.near, noon + 40 * min - 1, 40 * min - 1).when;
    try testing.expectEqual(When{ .form = .minutes, .n = 40 }, part);
    const m90 = whenOf(.near, noon + 90 * min, 90 * min).when;
    try testing.expectEqual(When{ .form = .minutes, .n = 90 }, m90);
    const h2 = whenOf(.near, noon + 91 * min, 91 * min).when;
    try testing.expectEqual(When{ .form = .hours, .n = 2 }, h2);
    const h3 = whenOf(.near, noon + 3 * hour, 3 * hour).when;
    try testing.expectEqual(When{ .form = .hours, .n = 3 }, h3);
    const d3 = whenOf(.near, noon + 3 * day, 3 * day).when;
    try testing.expectEqual(When{ .form = .days, .n = 3 }, d3);

    const clock = whenOf(.out, noon + 3 * hour, 3 * hour).when.form;
    try testing.expectEqual(When.Form.clock, clock);
    const date = whenOf(.out, noon + 3 * day, 3 * day).when.form;
    try testing.expectEqual(When.Form.date, date);
}

test "quota wake: it asks to be woken exactly when what it says would change, and says the next thing then" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Forty minutes and a bit: the next change is the minute turning.
    const resets = noon + 40 * min - 20_000;
    const r = [_]Reading{.{
        .family = .claude,
        .state = .have,
        .windows = .{ .{ .span = .five_hour, .used = 92, .resets_ms = resets }, null },
        .at_ms = noon,
    }};
    const first = try build(aa, &r, noon);
    try testing.expectEqual(@as(u32, 40), first.out.alerts[0].when.n);
    const wake = first.wake_ms.?;
    try testing.expectEqual(resets - 39 * min, wake);

    const before = try build(aa, &r, wake - 1);
    try testing.expectEqual(@as(u32, 40), before.out.alerts[0].when.n);
    const after = try build(aa, &r, wake);
    const n = after.out.alerts[0].when.n;
    try testing.expectEqual(@as(u32, 39), n);
}

test "quota wake: an ordinary day wakes for the number going old and for the window ending, and for nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const r = [_]Reading{have(.claude, win(.five_hour, 30, 3 * hour), null, noon)};

    const first = try build(aa, &r, noon);
    const wake = first.wake_ms;
    try testing.expectEqual(@as(?u64, noon + stale_after_ms), wake);

    // Old, and counted in hours: once an hour.
    const old = try build(aa, &r, noon + stale_after_ms);
    try testing.expectEqual(Entry.State.stale, old.out.line.?.entries[0].state);
    try testing.expectEqual(@as(?u64, noon + 2 * hour), old.wake_ms);

    // The last wake before the end is the end itself; after it, none.
    const late = try build(aa, &r, noon + 2 * hour);
    const end = late.wake_ms;
    try testing.expectEqual(@as(?u64, noon + 3 * hour), end);
    const over = try build(aa, &r, noon + 3 * hour);
    try testing.expectEqual(Entry.State.recovered, over.out.line.?.entries[0].state);
    const never = over.wake_ms;
    try testing.expectEqual(@as(?u64, null), never);
}

test "quota: when the numbers were taken is not what two blocks are told apart by" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const a = try built(aa, &.{have(.claude, win(.five_hour, 30, 3 * hour), null, noon - 2 * min)});
    const b = try built(aa, &.{have(.claude, win(.five_hour, 30, 3 * hour), null, noon - min)});
    const c = try built(aa, &.{have(.claude, win(.five_hour, 31, 3 * hour), null, noon - min)});

    const ja = try std.json.Stringify.valueAlloc(aa, try stripped(aa, a), .{});
    const jb = try std.json.Stringify.valueAlloc(aa, try stripped(aa, b), .{});
    const jc = try std.json.Stringify.valueAlloc(aa, try stripped(aa, c), .{});
    try testing.expectEqualStrings(ja, jb);
    const differs = !std.mem.eql(u8, jb, jc);
    try testing.expect(differs);
}

test "quota: Claude Code's status line input, in the shape 2.1.296 writes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const got = fromClaudeStatus(aa,
        \\{"session_id":"s","model":{"id":"m","display_name":"M"},"version":"2.1.296",
        \\ "rate_limits":{"five_hour":{"used_percentage":61,"resets_at":1700003600},
        \\                "seven_day":{"used_percentage":12.9,"resets_at":1700400000}}}
    ).?;
    try testing.expectEqual(Window{ .span = .five_hour, .used = 61, .resets_ms = 1_700_003_600_000 }, got[0].?);
    // Rounded down: a hundred is only ever all of it.
    try testing.expectEqual(@as(u8, 12), got[1].?.used);
    try testing.expectEqual(Span.seven_day, got[1].?.span);

    // Before the first answer of a session, and for an account that pays
    // by the token, there is no such field.
    const before = fromClaudeStatus(aa, "{\"session_id\":\"s\",\"version\":\"2.1.296\"}");
    try testing.expectEqual(@as(?[max_windows]?Window, null), before);
    try testing.expectEqual(@as(?[max_windows]?Window, null), fromClaudeStatus(aa, "{\"rate_limits\":null}"));
    try testing.expectEqual(@as(?[max_windows]?Window, null), fromClaudeStatus(aa, "not json"));

    const full = fromClaudeStatus(aa, "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":99.6,\"resets_at\":1700003600}}}").?;
    const almost = full[0].?.used;
    try testing.expectEqual(@as(u8, 99), almost);
}

test "quota: a Codex session's token_count line, with two windows, one, and none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const two = fromCodexLine(aa,
        \\{"timestamp":"2023-11-14T22:13:20.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":20.5,"window_minutes":300,"resets_at":1700003600},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1700400000},"credits":null,"plan_type":"plus"}}}
    ).?;
    try testing.expectEqual(@as(u64, 1_700_000_000_000), two.at_ms);
    try testing.expectEqual(Window{ .span = .five_hour, .used = 20, .resets_ms = 1_700_003_600_000 }, two.windows[0].?);
    try testing.expectEqual(Span.seven_day, two.windows[1].?.span);

    // A free account: one window, a month long.
    const one = fromCodexLine(aa,
        \\{"timestamp":"2023-11-14T22:13:20.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":43200,"resets_at":1702000000},"secondary":null}}}
    ).?;
    const span = one.windows[0].?.span;
    try testing.expectEqual(Span.month, span);
    try testing.expect(one.windows[1] == null);

    // An account that pays by the token: no window at all.
    const none = fromCodexLine(aa,
        \\{"timestamp":"2023-11-14T22:13:20.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":null,"secondary":null}}}
    );
    try testing.expect(none == null);

    const other = fromCodexLine(aa, "{\"timestamp\":\"2023-11-14T22:13:20.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"token_count\"}}");
    try testing.expect(other == null);
}

test "quota: what +statusline leaves is what the app reads back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const windows: [max_windows]?Window = .{ win(.five_hour, 61, hour), win(.seven_day, 12, day) };
    try writeDrop(&w, windows, noon);

    const got = readDrop(aa, .claude, w.buffered()).?;
    try testing.expect(got.eql(have(.claude, windows[0], windows[1], noon)));

    try testing.expect(readDrop(aa, .claude, "") == null);
    try testing.expect(readDrop(aa, .claude, "{\"v\":2,\"at_ms\":1,\"windows\":[]}") == null);
    const absurd = readDrop(aa, .claude, "{\"v\":1,\"at_ms\":1,\"windows\":[{\"span\":\"five_hour\",\"used\":140,\"resets_ms\":5}]}");
    try testing.expect(absurd == null);
}
