//! What one pane's reading means against its lines (task 1993, #1985 §3):
//! which warn lines were crossed, whether it is to be killed, and whether
//! the person is to be told. Plus the machine's own memory pressure (§3.4).
//!
//! **A line counts once a reading has stayed at or over it for `for_ms`**
//! (10 s by default: the sampler reads every 2 s, so six readings in a row).
//! A reading under the line in between starts the wait again.
//! **A line that counted counts again only after the reading fell under 80%
//! of it**, so a pane hovering at the line is one warning, not one every
//! ten seconds.
//! **At 1.5 times the kill line the pane is killed at once**, without the
//! wait and even while the person types: a pane growing that fast can take
//! the machine before ten seconds are up. Every one is marked `fast`, so the
//! history can say how often this shortcut was what killed.
//!
//! Two things hold a kill back, and neither holds a warning back:
//! - `protected` (shielded, held): the kill line only warns, as `withheld`.
//! - `typing` (a real key in the last 10 s): the kill waits until the person
//!   stops, unless it is a fast one.
//!
//! The person is told of the same line of the same pane at most once in ten
//! minutes (`tell_person`); every crossing is still an event, for the log
//! and the history. A kill is always told, and starts the count again
//! (`afterKill`): what comes after it is news.
//!
//! Pure: limits, a reading, the time and two flags in; events out. The
//! state is the caller's, one per pane, and goes back to `.fresh` whenever
//! the pane's limits change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../os/i18n.zig");
const limits = @import("limits.zig");
const Limits = limits.Limits;

/// Under this share of a line, the line counts again.
pub const rearm_percent = 80;
/// At this many tenths of the kill line, kill without waiting.
pub const fast_tenths = 15;
/// The person hears of one line of one pane at most this often.
pub const tell_every_ms: i64 = 10 * 60_000;

pub const Metric = enum { memory, processes };

/// A line of one metric: one of its warn lines, or its kill line.
pub const Line = union(enum) {
    warn: u8,
    kill,
};

pub const Event = struct {
    metric: Metric,
    line: Line,
    what: What,
    /// The reading, and the line it was judged against, both resolved:
    /// bytes for memory, a count for processes.
    value: u64,
    at: u64,
    /// Whether this one goes to the person as a system notification.
    tell_person: bool,

    pub const What = enum {
        /// A warn line counted.
        warn,
        /// The kill line counted on a pane that may not be killed.
        withheld,
        /// Kill the pane's agent.
        kill,
    };

    /// Kill without the wait: over `fast_tenths` of the kill line.
    pub fn isFast(self: Event) bool {
        return self.what == .kill and self.value * 10 >= self.at * fast_tenths;
    }
};

/// What a pane's state remembers of one line.
const Track = struct {
    /// Since when the reading has been at or over the line.
    over_since: ?i64,
    /// Whether the line may count (again).
    armed: bool,
    /// When the person was last told of this line.
    told_ms: ?i64,

    const fresh: Track = .{ .over_since = null, .armed = true, .told_ms = null };
};

const per_metric = limits.max_warns + 1;
pub const kill_slot = limits.max_warns;

pub const State = struct {
    memory: [per_metric]Track,
    processes: [per_metric]Track,

    pub const fresh: State = .{ .memory = @splat(.fresh), .processes = @splat(.fresh) };
};

pub const Reading = struct {
    mem: u64,
    procs: u32,
};

pub const Guard = struct {
    /// Shielded or held: the kill line only warns.
    protected: bool,
    /// A real key in the pane in the last 10 s: a kill that is not fast waits.
    typing: bool,

    pub const none: Guard = .{ .protected = false, .typing = false };
};

pub const Verdict = struct {
    events: [2 * per_metric]Event = undefined,
    len: u8 = 0,

    pub fn all(self: *const Verdict) []const Event {
        return self.events[0..self.len];
    }

    /// The kill, when there is one. Memory's first: it is the one the
    /// machine dies of.
    pub fn kill(self: *const Verdict) ?Event {
        for (self.all()) |e| if (e.what == .kill) return e;
        return null;
    }

    fn add(self: *Verdict, e: Event) void {
        self.events[self.len] = e;
        self.len += 1;
    }
};

/// One reading of one pane, at `now_ms` (monotonic), on a machine with
/// `phys` bytes.
pub fn step(state: *State, l: *const Limits, r: Reading, now_ms: i64, phys: u64, guard: Guard) Verdict {
    var v: Verdict = .{};
    metric(&v, .memory, &l.memory, &state.memory, r.mem, now_ms, phys, guard);
    metric(&v, .processes, &l.processes, &state.processes, r.procs, now_ms, phys, guard);
    return v;
}

fn metric(
    v: *Verdict,
    which: Metric,
    m: *const limits.Metric,
    tracks: *[per_metric]Track,
    value: u64,
    now_ms: i64,
    phys: u64,
    guard: Guard,
) void {
    for (m.warns(), 0..) |w, i| {
        const at = w.resolve(phys);
        if (cross(&tracks[i], value, at, now_ms, m.for_ms)) {
            v.add(.{ .metric = which, .line = .{ .warn = @intCast(i) }, .what = .warn, .value = value, .at = at, .tell_person = tell(&tracks[i], now_ms) });
        }
    }
    const k = m.kill orelse return;
    const at = k.resolve(phys);
    const t = &tracks[kill_slot];
    const fast = value * 10 >= at * fast_tenths;
    if (guard.protected) {
        if (cross(t, value, at, now_ms, m.for_ms))
            v.add(.{ .metric = which, .line = .kill, .what = .withheld, .value = value, .at = at, .tell_person = tell(t, now_ms) });
        return;
    }
    if (fast and t.armed) {
        t.armed = false;
        t.over_since = null;
        t.told_ms = now_ms;
        v.add(.{ .metric = which, .line = .kill, .what = .kill, .value = value, .at = at, .tell_person = true });
        return;
    }
    // Typing: the wait goes on, but the line is not allowed to count yet.
    if (guard.typing) {
        _ = over(t, value, at, now_ms);
        return;
    }
    if (cross(t, value, at, now_ms, m.for_ms)) {
        t.told_ms = now_ms;
        v.add(.{ .metric = which, .line = .kill, .what = .kill, .value = value, .at = at, .tell_person = true });
    }
}

/// The pane's agent was stopped: whatever its lines do next, the person is
/// told of it as of the first time (P4b). Seen on the machine: a pane
/// stopped at 22:43 and shielded at 22:47 crossed its kill line again, and
/// the person was not told it was withheld.
pub fn afterKill(state: *State) void {
    for (&state.memory) |*t| t.told_ms = null;
    for (&state.processes) |*t| t.told_ms = null;
}

/// Keeps the line's wait and its arming; true for how long it has been over.
fn over(t: *Track, value: u64, at: u64, now_ms: i64) ?i64 {
    if (value * 100 < at * rearm_percent) t.armed = true;
    if (value < at) {
        t.over_since = null;
        return null;
    }
    const since = t.over_since orelse now_ms;
    t.over_since = since;
    return now_ms - since;
}

/// Whether the line counts now: over it for `for_ms`, and armed.
fn cross(t: *Track, value: u64, at: u64, now_ms: i64, for_ms: u32) bool {
    const held = over(t, value, at, now_ms) orelse return false;
    if (held < for_ms or !t.armed) return false;
    t.armed = false;
    return true;
}

fn tell(t: *Track, now_ms: i64) bool {
    if (t.told_ms) |last| if (now_ms - last < tell_every_ms) return false;
    t.told_ms = now_ms;
    return true;
}

// ------------------------------------------------------------- the words

/// "19.4 GB", "512 MB": one decimal over a gigabyte, whole megabytes under.
pub fn bytesText(buf: []u8, b: u64) []const u8 {
    const gb: u64 = 1 << 30;
    if (b >= gb) {
        const tenths = (b * 10 + gb / 2) / gb;
        return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ tenths / 10, tenths % 10 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} MB", .{(b + (1 << 19)) >> 20}) catch "";
}

/// A process name as it may be written: the kernel's short name is cut at
/// 16 bytes, which can cut a character in two, and nothing stops it holding
/// a control byte. Anything but printable ASCII becomes `?`.
pub fn safeName(buf: []u8, name: []const u8) []const u8 {
    const n = @min(buf.len, name.len);
    for (name[0..n], buf[0..n]) |c, *o| o.* = if (c >= 0x20 and c < 0x7f) c else '?';
    return buf[0..n];
}

/// A msgid in the person's language: `i18n._` in the app, `english` (the
/// msgid itself) or a catalogue in a test -- as `ControlFix.Tr`.
pub const Tr = *const fn (msgid: [:0]const u8) []const u8;

pub fn english(msgid: [:0]const u8) []const u8 {
    return msgid;
}

/// Every sentence the person is told about a pane's lines (task 1993):
/// the note in the pane and the system notifications. English msgids, said
/// in the person's language through `po/`; `{1}`… are filled as
/// `ControlRoom.Say.fill` fills them, with numbers that are not translated.
pub const words = struct {
    pub const kill_memory = i18n.N_("Polter stopped this pane: memory {1}, over its kill line of {2} for {3} s");
    pub const kill_memory_fast = i18n.N_("Polter stopped this pane at once: memory {1}, over 1.5 times its kill line of {2}");
    pub const kill_processes = i18n.N_("Polter stopped this pane: {1} processes, over its kill line of {2} for {3} s");
    pub const kill_processes_fast = i18n.N_("Polter stopped this pane at once: {1} processes, over 1.5 times its kill line of {2}");
    pub const warn_memory = i18n.N_("Memory {1}, over warn line {2} of {3}");
    pub const warn_processes = i18n.N_("{1} processes, over warn line {2} of {3}");
    pub const withheld_memory = i18n.N_("Memory {1}, over its kill line of {2}; it is held or shielded, so it was not stopped");
    pub const withheld_processes = i18n.N_("{1} processes, over its kill line of {2}; it is held or shielded, so it was not stopped");
    pub const most = i18n.N_("{1}; most of it was {2} ({3} processes)");
    pub const kill_title = i18n.N_("Polter stopped a pane");
    pub const warn_title = i18n.N_("A pane is over a line");
    pub const pressure_title = i18n.N_("The machine is short of memory");
    pub const pressure_warn = i18n.N_("Memory pressure is high. Holding the most: {1}");
    pub const pressure_critical = i18n.N_("Memory pressure is critical. Holding the most: {1}");

    /// Every msgid above, for the test that each is translated.
    pub const all = [_][:0]const u8{
        kill_memory,   kill_memory_fast,  kill_processes,  kill_processes_fast,
        warn_memory,   warn_processes,    withheld_memory, withheld_processes,
        most,          kill_title,        warn_title,      pressure_title,
        pressure_warn, pressure_critical,
    };
};

/// What a stopped pane's note and notification say (task 1993): the
/// reading, the line, and who held the most. Plain text, no rules round it
/// (the pane's note adds them).
pub fn killText(arena: Allocator, tr: Tr, e: Event, for_ms: u32, top: []const u8, top_count: u32) Allocator.Error![]const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    var sec: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&sec, "{d}", .{for_ms / 1000}) catch "";
    const fast = e.isFast();
    const said = switch (e.metric) {
        .memory => try fill(arena, tr(if (fast) words.kill_memory_fast else words.kill_memory), &.{ bytesText(&a, e.value), bytesText(&b, e.at), secs }),
        .processes => try fill(arena, tr(if (fast) words.kill_processes_fast else words.kill_processes), &.{ countText(&a, e.value), countText(&b, e.at), secs }),
    };
    return withMost(arena, tr, said, top, top_count);
}

/// A warn line, or a kill line on a pane that may not be stopped.
pub fn warnText(arena: Allocator, tr: Tr, e: Event, top: []const u8, top_count: u32) Allocator.Error![]const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    var n: [4]u8 = undefined;
    const which = switch (e.line) {
        .warn => |i| std.fmt.bufPrint(&n, "{d}", .{@as(u32, i) + 1}) catch "",
        .kill => "",
    };
    const said = switch (e.metric) {
        .memory => switch (e.what) {
            .withheld => try fill(arena, tr(words.withheld_memory), &.{ bytesText(&a, e.value), bytesText(&b, e.at) }),
            else => try fill(arena, tr(words.warn_memory), &.{ bytesText(&a, e.value), which, bytesText(&b, e.at) }),
        },
        .processes => switch (e.what) {
            .withheld => try fill(arena, tr(words.withheld_processes), &.{ countText(&a, e.value), countText(&b, e.at) }),
            else => try fill(arena, tr(words.warn_processes), &.{ countText(&a, e.value), which, countText(&b, e.at) }),
        },
    };
    return withMost(arena, tr, said, top, top_count);
}

fn withMost(arena: Allocator, tr: Tr, said: []const u8, top: []const u8, top_count: u32) Allocator.Error![]const u8 {
    if (top.len == 0) return said;
    var nm: [16]u8 = undefined;
    var c: [16]u8 = undefined;
    return fill(arena, tr(words.most), &.{ said, safeName(&nm, top), countText(&c, top_count) });
}

fn countText(buf: []u8, n: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
}

const fill = @import("ControlRoom.zig").Say.fill;

// ------------------------------------------------------- machine pressure

pub const Pressure = enum(u8) {
    normal,
    warn,
    critical,

    /// `kern.memorystatus_vm_pressure_level`: 1, 2, 4.
    pub fn fromKernel(level: u32) Pressure {
        return switch (level) {
            4 => .critical,
            2 => .warn,
            else => .normal,
        };
    }
};

/// The machine's pressure is told to the person, never to a supervisor,
/// and never kills a pane: a level that held for 10 s, each level at most
/// once in ten minutes.
pub const PressureState = struct {
    level: Pressure,
    since: i64,
    told_ms: [2]?i64,

    pub const fresh: PressureState = .{ .level = .normal, .since = 0, .told_ms = .{ null, null } };
};

pub const pressure_for_ms: i64 = 10_000;

/// The level to tell the person of now, if any.
pub fn pressureStep(s: *PressureState, level: Pressure, now_ms: i64) ?Pressure {
    if (level != s.level) {
        s.level = level;
        s.since = now_ms;
    }
    if (level == .normal or now_ms - s.since < pressure_for_ms) return null;
    const slot = &s.told_ms[@intFromEnum(level) - 1];
    if (slot.*) |last| if (now_ms - last < tell_every_ms) return null;
    slot.* = now_ms;
    return level;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const G: u64 = 1 << 30;

fn lim(text: []const u8) !Limits {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer p.deinit();
    var why: []const u8 = "";
    return limits.parse(p.value, &why);
}

/// One row of a table: at `t` seconds the pane holds `gb`; `want` is the
/// events, written "w0", "w1", "k", "K" (fast kill), "x" (withheld), with a
/// trailing "!" when the person is told.
const Row = struct { t: i64, gb: u64, want: []const u8, guard: Guard = .none };

fn run(l: *const Limits, rows: []const Row) !void {
    var s: State = .fresh;
    for (rows) |row| {
        const v = step(&s, l, .{ .mem = row.gb * G, .procs = 1 }, row.t * 1000, 32 * G, row.guard);
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (v.all(), 0..) |e, i| {
            if (i > 0) try w.writeByte(' ');
            switch (e.what) {
                .warn => try w.print("w{d}", .{e.line.warn}),
                .kill => try w.writeAll(if (e.isFast()) "K" else "k"),
                .withheld => try w.writeAll("x"),
            }
            if (e.tell_person) try w.writeByte('!');
        }
        testing.expectEqualStrings(row.want, w.buffered()) catch |err| {
            std.debug.print("at t={d}s, {d} GB\n", .{ row.t, row.gb });
            return err;
        };
    }
}

test "1993: a line counts after ten seconds over it, and again only after falling under 80%" {
    const l = try lim("{\"memory\": {\"warn\": [\"10G\"]}}");
    try run(&l, &.{
        .{ .t = 0, .gb = 11, .want = "" },
        .{ .t = 8, .gb = 11, .want = "" },
        .{ .t = 10, .gb = 11, .want = "w0!" },
        // Still over: counted already.
        .{ .t = 12, .gb = 12, .want = "" },
        // Under the line but not under 8 GB: still not armed.
        .{ .t = 14, .gb = 9, .want = "" },
        .{ .t = 16, .gb = 11, .want = "" },
        .{ .t = 30, .gb = 11, .want = "" },
        // Under 80%: armed again, but the person was told under ten
        // minutes ago, so this one is for the log only.
        .{ .t = 32, .gb = 7, .want = "" },
        .{ .t = 34, .gb = 11, .want = "" },
        .{ .t = 44, .gb = 11, .want = "w0" },
        // Ten minutes after the first telling, the person hears again.
        .{ .t = 50, .gb = 7, .want = "" },
        .{ .t = 610, .gb = 11, .want = "" },
        .{ .t = 620, .gb = 11, .want = "w0!" },
    });
}

test "1993: a dip under the line starts the wait again" {
    const l = try lim("{\"memory\": {\"warn\": [\"10G\"], \"for\": \"30s\"}}");
    try run(&l, &.{
        .{ .t = 0, .gb = 11, .want = "" },
        .{ .t = 28, .gb = 9, .want = "" },
        .{ .t = 30, .gb = 11, .want = "" },
        .{ .t = 58, .gb = 11, .want = "" },
        .{ .t = 60, .gb = 11, .want = "w0!" },
    });
}

test "1993: several warn lines and a kill, each counted on its own" {
    const l = try lim("{\"memory\": {\"warn\": [\"8G\", \"13G\"], \"kill\": \"19G\"}}");
    try run(&l, &.{
        .{ .t = 0, .gb = 14, .want = "" },
        .{ .t = 10, .gb = 14, .want = "w0! w1!" },
        .{ .t = 12, .gb = 20, .want = "" },
        .{ .t = 22, .gb = 20, .want = "k!" },
        // The agent is gone; the shell is left with little.
        .{ .t = 24, .gb = 0, .want = "" },
    });
}

test "1993: at one and a half times the kill line it kills at once, even while typing" {
    const l = try lim("{\"memory\": {\"kill\": \"10G\"}}");
    try run(&l, &.{
        .{ .t = 0, .gb = 14, .want = "" },
        .{ .t = 2, .gb = 15, .want = "K!", .guard = .{ .protected = false, .typing = true } },
        // Once killed, not again until it has been under 80%.
        .{ .t = 4, .gb = 30, .want = "" },
        .{ .t = 6, .gb = 7, .want = "" },
        .{ .t = 8, .gb = 15, .want = "K!" },
    });
}

test "1993: typing holds a kill back until the person stops, and a protected pane is only warned" {
    const l = try lim("{\"memory\": {\"warn\": [\"8G\"], \"kill\": \"10G\"}}");
    const typing: Guard = .{ .protected = false, .typing = true };
    try run(&l, &.{
        .{ .t = 0, .gb = 11, .want = "", .guard = typing },
        // The warn line is not held back; the kill line is.
        .{ .t = 10, .gb = 11, .want = "w0!", .guard = typing },
        .{ .t = 30, .gb = 11, .want = "", .guard = typing },
        // The person stopped: it has been over for 32 s, so now.
        .{ .t = 32, .gb = 11, .want = "k!" },
    });
    const shielded: Guard = .{ .protected = true, .typing = false };
    try run(&l, &.{
        .{ .t = 0, .gb = 16, .want = "", .guard = shielded },
        .{ .t = 10, .gb = 16, .want = "w0! x!", .guard = shielded },
        .{ .t = 20, .gb = 40, .want = "", .guard = shielded },
    });
}

test "1993: after a kill the pane's lines are told to the person again, even within ten minutes" {
    const l = try lim("{\"memory\": {\"warn\": [\"8G\"], \"kill\": \"10G\"}}");
    const shielded: Guard = .{ .protected = true, .typing = false };
    var s: State = .fresh;
    _ = step(&s, &l, .{ .mem = 11 * G, .procs = 3 }, 0, 32 * G, .none);
    const killed = step(&s, &l, .{ .mem = 11 * G, .procs = 3 }, 10_000, 32 * G, .none);
    try testing.expect(killed.kill() != null);
    afterKill(&s);
    // The shell is left with little; four minutes on, shielded now, it
    // climbs over both lines again.
    _ = step(&s, &l, .{ .mem = 0, .procs = 1 }, 12_000, 32 * G, .none);
    _ = step(&s, &l, .{ .mem = 11 * G, .procs = 3 }, 250_000, 32 * G, shielded);
    const v = step(&s, &l, .{ .mem = 11 * G, .procs = 3 }, 260_000, 32 * G, shielded);
    try testing.expectEqual(@as(usize, 2), v.all().len);
    try testing.expectEqual(Event.What.warn, v.all()[0].what);
    const warned_told = v.all()[0].tell_person;
    try testing.expect(warned_told);
    try testing.expectEqual(Event.What.withheld, v.all()[1].what);
    const withheld_told = v.all()[1].tell_person;
    try testing.expect(withheld_told);
}

test "1993: process counts are judged like memory, and a share follows the machine" {
    const l = try lim("{\"memory\": {\"warn\": [\"50%\"]}, \"processes\": {\"kill\": 100}}");
    var s: State = .fresh;
    _ = step(&s, &l, .{ .mem = 20 * G, .procs = 120 }, 0, 32 * G, .none);
    const v = step(&s, &l, .{ .mem = 20 * G, .procs = 120 }, 10_000, 32 * G, .none);
    try testing.expectEqual(@as(usize, 2), v.all().len);
    try testing.expectEqual(Metric.memory, v.all()[0].metric);
    try testing.expectEqual(16 * G, v.all()[0].at);
    const k = v.kill().?;
    try testing.expectEqual(Metric.processes, k.metric);
    try testing.expectEqual(@as(u64, 120), k.value);
    try testing.expect(!k.isFast());
    // On a 64 GB machine 20 GB is under half: no warning.
    var s2: State = .fresh;
    _ = step(&s2, &l, .{ .mem = 20 * G, .procs = 1 }, 0, 64 * G, .none);
    try testing.expectEqual(@as(usize, 0), step(&s2, &l, .{ .mem = 20 * G, .procs = 1 }, 10_000, 64 * G, .none).all().len);
}

test "1993: no limits, no events" {
    var s: State = .fresh;
    const v = step(&s, &Limits.none, .{ .mem = 1 << 40, .procs = 100_000 }, 0, 32 * G, .none);
    try testing.expectEqual(@as(usize, 0), v.all().len);
    try testing.expectEqual(@as(?Event, null), step(&s, &Limits.none, .{ .mem = 1 << 40, .procs = 100_000 }, 60_000, 32 * G, .none).kill());
}

test "1993: machine pressure is told after ten seconds, each level once in ten minutes" {
    var s: PressureState = .fresh;
    const Case = struct { t: i64, level: Pressure, want: ?Pressure };
    const cases = [_]Case{
        .{ .t = 0, .level = .warn, .want = null },
        .{ .t = 8, .level = .warn, .want = null },
        .{ .t = 10, .level = .warn, .want = .warn },
        .{ .t = 12, .level = .warn, .want = null },
        // A new level waits its own ten seconds.
        .{ .t = 14, .level = .critical, .want = null },
        .{ .t = 24, .level = .critical, .want = .critical },
        // Back to warn: told under ten minutes ago.
        .{ .t = 30, .level = .warn, .want = null },
        .{ .t = 40, .level = .warn, .want = null },
        .{ .t = 50, .level = .normal, .want = null },
        .{ .t = 700, .level = .warn, .want = null },
        .{ .t = 710, .level = .warn, .want = .warn },
    };
    for (cases) |c| try testing.expectEqual(c.want, pressureStep(&s, c.level, c.t * 1000));
    try testing.expectEqual(Pressure.critical, Pressure.fromKernel(4));
    try testing.expectEqual(Pressure.normal, Pressure.fromKernel(1));
}

test "1993: a stopped pane is told what, against which line, and who held the most" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slow: Event = .{ .metric = .memory, .line = .kill, .what = .kill, .value = 19_400 << 20, .at = 19 * G, .tell_person = true };
    try testing.expectEqualStrings(
        "Polter stopped this pane: memory 18.9 GB, over its kill line of 19.0 GB for 10 s; most of it was python3.13 (7 processes)",
        try killText(a, english, slow, 10_000, "python3.13", 7),
    );
    const fast: Event = .{ .metric = .processes, .line = .kill, .what = .kill, .value = 3100, .at = 2000, .tell_person = true };
    try testing.expectEqualStrings(
        "Polter stopped this pane at once: 3100 processes, over 1.5 times its kill line of 2000",
        try killText(a, english, fast, 10_000, "", 0),
    );
    const warn: Event = .{ .metric = .memory, .line = .{ .warn = 1 }, .what = .warn, .value = 14 * G, .at = 13 * G, .tell_person = true };
    try testing.expectEqualStrings("Memory 14.0 GB, over warn line 2 of 13.0 GB", try warnText(a, english, warn, "", 0));
    const held: Event = .{ .metric = .memory, .line = .kill, .what = .withheld, .value = 20 * G, .at = 19 * G, .tell_person = true };
    try testing.expectEqualStrings(
        "Memory 20.0 GB, over its kill line of 19.0 GB; it is held or shielded, so it was not stopped",
        try warnText(a, english, held, "", 0),
    );
    // A name cut in the middle of a character, or carrying an escape.
    const cut = try killText(a, english, slow, 10_000, "\xe4\xb8\x1b[?1049h", 1);
    try testing.expect(std.mem.indexOfScalar(u8, cut, 0x1b) == null);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512 MB", bytesText(&buf, 512 << 20));
}

test "1993: every sentence about a pane's lines is in po/zh_CN.po" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalogue = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "po/zh_CN.po", a, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read po/zh_CN.po ({t}). Run `zig build test` from the repository root.\n", .{err});
        return error.SourceUnreadable;
    };
    for (words.all) |msgid| {
        const found = try i18n.po_text.lookup(a, catalogue, msgid);
        const said = found orelse {
            std.debug.print("not in po/zh_CN.po: {s}\n", .{msgid});
            return error.Untranslated;
        };
        try testing.expect(said.len > 0 and !std.mem.eql(u8, said, msgid));
    }
}
