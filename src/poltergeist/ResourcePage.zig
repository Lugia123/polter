//! The performance page's answer (task 2015 Q3, `polter-artifacts/2015/API.md`
//! §2.1): one group's terminals as the cards and the history grid draw
//! them, every word already written in the person's language and every
//! colour given as a level (`tone`), so neither host decides anything
//! (`tools/control-room-hosts-do-not-decide.py`).
//!
//! Pure: what the app knows of each pane in, the JSON out. The app gathers
//! (`App.controlPage`); this only says.

const ResourcePage = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const judge = @import("judge.zig");
const limits = @import("limits.zig");
const ledger = @import("ledger.zig");
const History = @import("ResourceHistory.zig");
const Grid = @import("ResourceGrid.zig");
const Recent = @import("ResourceRecent.zig");
const fill = @import("ControlRoom.zig").Say.fill;
const i18n = @import("../os/i18n.zig");

const Tr = judge.Tr;
const Level = History.Level;

/// 7 days: a day's cells, the first of each dated.
const day_cells = 6;

/// How long a stopped pane's card says so after the stop.
pub const killed_shown_ms: i64 = 10 * 60 * 1000;

/// What the page calls a level: `Level`, and `none` for no reading.
pub const Tone = enum { none, ok, warn1, warn2, warn3, warn4, withheld, killed };

pub fn toneOf(level: ?Level) Tone {
    const l = level orelse return .none;
    return switch (l) {
        .ok => .ok,
        .warn1 => .warn1,
        .warn2 => .warn2,
        .warn3 => .warn3,
        .warn4 => .warn4,
        .withheld => .withheld,
        .killed => .killed,
    };
}

pub const Role = enum {
    /// The group's supervisor.
    supervisor,
    /// Somebody in it with an agent.
    worker,
    /// A terminal of the person's: no agent in it.
    own,
};

/// The last stop of a pane, while the card still says so.
pub const Killed = struct {
    at_ms: i64,
    metric: judge.Metric,
    /// The reading the stop was for, and the line.
    value: u64,
    at: u64,
};

pub const Pane = struct {
    id: u64,
    name: []const u8,
    role: Role,
    /// Null: not read (yet).
    usage: ?ledger.Usage,
    lim: limits.Limits,
    /// The judge's level now; `ok` for a pane with no lines.
    level: Level,
    recent: ?*const Recent,
    killed: ?Killed,
};

pub const Machine = struct {
    used: ?u64,
    phys: ?u64,
    swap: ?u64,
    /// The kernel's word: 1 normal, 2 warn, 4 critical.
    pressure: ?u32,
};

pub const In = struct {
    group: []const u8,
    /// This reading's `seq`, and the last the page has (0 for none).
    seq: u64,
    since: u64,
    now_ms: i64,
    offset_ms: i64,
    period_ms: u32,
    machine: Machine,
    /// The group's terminals, in the order to draw them.
    panes: []const Pane,
    grid: *const Grid.Grid,
    /// Cells of the last 24 hours with a stop in them, and with a warning
    /// -- whichever span the grid is.
    kills_24h: usize,
    warns_24h: usize,
    /// The name of a pane in the grid that is not among `panes` -- one
    /// that has closed; null when it was never written down.
    gone_name: *const fn (ctx: *const anyopaque, id: u64) ?[]const u8,
    gone_ctx: *const anyopaque,
    tr: Tr,
};

pub const words = struct {
    pub const machine = i18n.N_("Machine");
    pub const of = i18n.N_("/ {1}");
    pub const swap = i18n.N_("Swap {1}");
    pub const pressure = i18n.N_("Memory pressure {1}");
    pub const pressure_normal = i18n.N_("normal");
    pub const pressure_warn = i18n.N_("high");
    pub const pressure_critical = i18n.N_("critical");
    pub const panes = i18n.N_("{1} terminals in this group");
    pub const day = i18n.N_("In 24 hours: stopped {1} times · {2} warnings");
    pub const now_line = i18n.N_("Now {1} terminals · {2} warning · {3} stopped");
    pub const now_note = i18n.N_("Every 2 s · a full dial is the line written in its gap");
    pub const span_day = i18n.N_("24 hours");
    pub const span_week = i18n.N_("7 days");
    pub const title_day = i18n.N_("Last 24 hours");
    pub const title_week = i18n.N_("Last 7 days");
    pub const sub_day = i18n.N_("A cell is 30 minutes, coloured by the highest level in it");
    pub const sub_week = i18n.N_("A cell is 4 hours, coloured by the highest level in it");
    pub const legend_none = i18n.N_("Absent");
    pub const legend_ok = i18n.N_("Normal");
    pub const legend_warn = i18n.N_("Warning {1}");
    pub const legend_killed = i18n.N_("Stopped");
    pub const yesterday = i18n.N_("Yesterday {1}");
    pub const now = i18n.N_("Now");
    pub const tip_killed = i18n.N_("{1}  {2} was stopped");
    pub const tip_withheld = i18n.N_("{1}  {2} was over its kill line, not stopped");
    pub const tip_warn = i18n.N_("{1}  {2} went over warn line {3}");
    pub const tip_peak = i18n.N_("{1}  {2} held at most {3}");
    pub const tip_memory_kill = i18n.N_("Memory {1}, over the kill line {2} for {3} s");
    pub const tip_memory_fast = i18n.N_("Memory {1}, over 1.5 times the kill line {2}");
    pub const tip_memory_warn = i18n.N_("Memory {1}, over the warn line {2}");
    pub const tip_processes_kill = i18n.N_("{1} processes, over the kill line {2} for {3} s");
    pub const tip_processes_fast = i18n.N_("{1} processes, over 1.5 times the kill line {2}");
    pub const tip_processes_warn = i18n.N_("{1} processes, over the warn line {2}");
    pub const tip_largest = i18n.N_("Largest: {1} ×{2}");
    pub const tip_told_both = i18n.N_("You and the supervisor were told");
    pub const tip_told_supervisor = i18n.N_("The supervisor was told, with the command to resume");
    pub const tip_told_person = i18n.N_("You were told");
    pub const tip_told_none = i18n.N_("Nobody was told: told of it under ten minutes before");
    pub const role_supervisor = i18n.N_("Supervisor");
    pub const role_own = i18n.N_("Your terminal");
    pub const badge_warn = i18n.N_("Warning {1}");
    pub const badge_withheld = i18n.N_("Over, not stopped");
    pub const badge_killed = i18n.N_("Stopped {1}");
    pub const cap_kill = i18n.N_("Kill line {1}");
    pub const cap_machine = i18n.N_("Machine {1}");
    pub const rising = i18n.N_("↗ +{1}/min");
    pub const falling = i18n.N_("↘ −{1}/min");
    pub const level_trend = i18n.N_("→ Steady");
    pub const stopped = i18n.N_("↓ Stopped");
    pub const minutes_to = i18n.N_("About {1} min to the line");
    pub const short_of = i18n.N_("{1} to go");
    pub const no_line = i18n.N_("No kill line");
    pub const stopped_at = i18n.N_("Stopped at {1}");
    pub const over = i18n.N_("Over the line");
    pub const foot_cpu = i18n.N_("CPU {1} cores · {2} processes");
    pub const foot_procs = i18n.N_("{1} processes");
    pub const foot_ran = i18n.N_("Ran {1}");
    pub const foot_resume = i18n.N_("Resume command given to the supervisor");

    pub const all = [_][:0]const u8{
        machine,             of,                 swap,               pressure,        pressure_normal,
        pressure_warn,       pressure_critical,  panes,              day,             now_line,
        now_note,            span_day,           span_week,          title_day,       title_week,
        sub_day,             sub_week,           legend_none,        legend_ok,       legend_warn,
        legend_killed,       yesterday,          now,                tip_killed,      tip_withheld,
        tip_warn,            tip_peak,           tip_memory_kill,    tip_memory_fast, tip_memory_warn,
        tip_processes_kill,  tip_processes_fast, tip_processes_warn, tip_largest,     tip_told_both,
        tip_told_supervisor, tip_told_person,    tip_told_none,      role_supervisor, role_own,
        badge_warn,          badge_withheld,     badge_killed,       cap_kill,        cap_machine,
        rising,              falling,            level_trend,        stopped,         minutes_to,
        short_of,            no_line,            stopped_at,         over,            foot_cpu,
        foot_procs,          foot_ran,           foot_resume,
    };
};

// ------------------------------------------------------------- the shape

const Line = struct { tone: ?Tone, text: []const u8 };
const Text = struct { tone: ?Tone, text: []const u8 };

const Out = struct {
    page: []const u8 = "resources",
    group: []const u8,
    seq: u64,
    full: bool,
    period_ms: u32,
    now_ms: i64,
    machine: struct {
        text: struct {
            label: []const u8,
            mem: ?[]const u8,
            mem_of: ?[]const u8,
            swap: ?[]const u8,
            pressure: ?[]const u8,
            panes: []const u8,
            day: []const u8,
        },
        pressure_tone: ?Tone,
    },
    now_line: []const u8,
    now_note: []const u8,
    grid: GridOut,
    cards: []const Card,
};

const GridOut = struct {
    span: Grid.Span,
    spans: []const struct { span: Grid.Span, text: []const u8 },
    title: []const u8,
    subtitle: []const u8,
    legend: []const struct { tone: Tone, text: []const u8 },
    start_ms: i64,
    cell_ms: i64,
    cells: usize,
    axis: []const struct { cell: usize, text: []const u8 },
    /// One per terminal: its strip of cells. Not `rows`, which is the
    /// control room's list (`tools/control-room-hosts-do-not-decide.py`).
    panes: []const Row,
};

const Row = struct {
    id: []const u8,
    name: []const u8,
    cells: []const Tone,
    hover: []const struct { cell: usize, lines: []const Line },
};

const Card = struct {
    id: []const u8,
    name: []const u8,
    role: ?[]const u8,
    badge: ?Text,
    tone: Tone,
    dial: struct {
        fraction: f64,
        ticks: []const f64,
        big: []const u8,
        unit: []const u8 = "%",
        cap: []const u8,
    },
    /// The four lines right of the dial. Not `rows` (see `GridOut.panes`).
    lines: struct {
        r1: ?struct { value: []const u8, rest: []const u8 },
        r2: ?Text,
        r3: ?Text,
        r4: []const u8 = "curve",
    },
    foot: struct { left: []const u8, right: []const u8 },
    line_at: ?u64,
    points: []const [2]i64,
    raw: struct { mem: u64, procs: u32, cpu_milli: ?u32, run_s: ?i64 },
};

// ------------------------------------------------------------ the saying

/// The page as JSON, in `arena`.
pub fn render(arena: Allocator, in: In) Allocator.Error![]u8 {
    const tr = in.tr;
    const full = in.since == 0;

    var warning: usize = 0;
    var stopped: usize = 0;
    const cards = try arena.alloc(Card, in.panes.len);
    for (in.panes, cards) |p, *c| {
        c.* = try card(arena, in, p);
        switch (c.tone) {
            .warn1, .warn2, .warn3, .warn4, .withheld => warning += 1,
            .killed => stopped += 1,
            else => {},
        }
    }

    const m = in.machine;

    const out: Out = .{
        .group = in.group,
        .seq = in.seq,
        .full = full,
        .period_ms = in.period_ms,
        .now_ms = in.now_ms,
        .machine = .{
            .text = .{
                .label = tr(words.machine),
                .mem = if (m.used) |u| try gbNumber(arena, u) else null,
                .mem_of = if (m.phys) |p| try fill(arena, tr(words.of), &.{try bytes(arena, p)}) else null,
                .swap = if (m.swap) |s| try fill(arena, tr(words.swap), &.{try bytes(arena, s)}) else null,
                .pressure = if (m.pressure) |p| try fill(arena, tr(words.pressure), &.{tr(switch (p) {
                    4 => words.pressure_critical,
                    2 => words.pressure_warn,
                    else => words.pressure_normal,
                })}) else null,
                .panes = try fill(arena, tr(words.panes), &.{try num(arena, in.panes.len)}),
                .day = try fill(arena, tr(words.day), &.{ try num(arena, in.kills_24h), try num(arena, in.warns_24h) }),
            },
            .pressure_tone = if (m.pressure) |p| switch (p) {
                4 => .killed,
                2 => .warn1,
                else => .ok,
            } else null,
        },
        .now_line = try fill(arena, tr(words.now_line), &.{ try num(arena, in.panes.len), try num(arena, warning), try num(arena, stopped) }),
        .now_note = tr(words.now_note),
        .grid = try gridOut(arena, in),
        .cards = cards,
    };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

fn card(arena: Allocator, in: In, p: Pane) Allocator.Error!Card {
    const tr = in.tr;
    const phys = in.machine.phys orelse 0;
    const u = p.usage;
    const mem: u64 = if (u) |x| x.mem else 0;
    const kill_at: ?u64 = if (p.lim.memory.kill) |k| k.resolve(phys) else null;
    const killed = if (p.killed) |k| (if (in.now_ms - k.at_ms <= killed_shown_ms) k else null) else null;

    const tone: Tone = if (killed != null) .killed else if (u == null) .none else toneOf(p.level);
    // The dial's whole: the kill line, else the machine.
    const whole: u64 = kill_at orelse phys;
    const shown: u64 = if (killed) |k| (if (k.metric == .memory) k.value else mem) else mem;
    const fraction: f64 = if (whole == 0) 0 else @as(f64, @floatFromInt(shown)) / @as(f64, @floatFromInt(whole));
    var ticks: std.ArrayListUnmanaged(f64) = .empty;
    if (kill_at) |k| if (k > 0) for (p.lim.memory.warns()) |w| {
        try ticks.append(arena, @as(f64, @floatFromInt(w.resolve(phys))) / @as(f64, @floatFromInt(k)));
    };

    const recent = p.recent;
    const trend: ?Recent.Trend = if (recent) |r| r.trend() else null;

    const r2: ?Text = if (killed != null)
        .{ .tone = null, .text = tr(words.stopped) }
    else if (trend) |t|
        (if (t.flat)
            .{ .tone = null, .text = tr(words.level_trend) }
        else if (t.per_min > 0)
            .{ .tone = warnTone(tone), .text = try fill(arena, tr(words.rising), &.{try bytes(arena, @intCast(t.per_min))}) }
        else
            .{ .tone = null, .text = try fill(arena, tr(words.falling), &.{try bytes(arena, @intCast(-t.per_min))}) })
    else
        null;

    const r3: ?Text = if (killed) |k|
        .{ .tone = .killed, .text = try fill(arena, tr(words.stopped_at), &.{try clock(arena, k.at_ms, in.offset_ms)}) }
    else if (u == null)
        null
    else if (kill_at) |k|
        (if (mem >= k)
            .{ .tone = .killed, .text = tr(words.over) }
        else if (if (recent) |r| r.secondsTo(k) else null) |secs|
            .{ .tone = warnTone(tone), .text = try fill(arena, tr(words.minutes_to), &.{try num(arena, @max(1, @divFloor(secs + 59, 60)))}) }
        else
            .{ .tone = null, .text = try fill(arena, tr(words.short_of), &.{try bytes(arena, k - mem)}) })
    else
        .{ .tone = null, .text = tr(words.no_line) };

    const cpu: ?u32 = if (recent) |r| r.cpu_milli else null;
    const run: ?i64 = if (recent) |r| r.runSeconds(in.now_ms) else null;
    const procs: u32 = if (u) |x| x.procs else 0;
    const left: []const u8 = if (killed != null)
        tr(words.foot_resume)
    else if (cpu) |c|
        try fill(arena, tr(words.foot_cpu), &.{ try cores(arena, c), try num(arena, procs) })
    else
        try fill(arena, tr(words.foot_procs), &.{try num(arena, procs)});
    const right: []const u8 = if (run) |s| try fill(arena, tr(words.foot_ran), &.{try hoursMinutes(arena, s)}) else "";

    var points: std.ArrayListUnmanaged([2]i64) = .empty;
    if (recent) |r| {
        var i = r.firstAfter(in.since);
        while (i < r.len) : (i += 1) {
            const pt = r.at(i);
            try points.append(arena, .{ pt.at_ms, @intCast(@min(pt.mem, std.math.maxInt(i64))) });
        }
    }

    return .{
        .id = try hex(arena, p.id),
        .name = p.name,
        .role = switch (p.role) {
            .supervisor => tr(words.role_supervisor),
            .own => tr(words.role_own),
            .worker => null,
        },
        .badge = switch (tone) {
            .warn1, .warn2, .warn3, .warn4 => .{ .tone = tone, .text = try fill(arena, tr(words.badge_warn), &.{try num(arena, @intFromEnum(tone) - @intFromEnum(Tone.warn1) + 1)}) },
            .withheld => .{ .tone = tone, .text = tr(words.badge_withheld) },
            .killed => .{ .tone = tone, .text = try fill(arena, tr(words.badge_killed), &.{try clock(arena, killed.?.at_ms, in.offset_ms)}) },
            .none, .ok => null,
        },
        .tone = tone,
        .dial = .{
            .fraction = fraction,
            .ticks = ticks.items,
            .big = try num(arena, @as(u64, @intFromFloat(@round(@max(0, fraction) * 100)))),
            .cap = if (kill_at) |k|
                try fill(arena, tr(words.cap_kill), &.{try bytes(arena, k)})
            else
                try fill(arena, tr(words.cap_machine), &.{try bytes(arena, phys)}),
        },
        .lines = .{
            .r1 = if (u == null) null else .{
                .value = try gbNumber(arena, mem),
                .rest = if (kill_at) |k| try fill(arena, tr(words.of), &.{try bytes(arena, k)}) else unitOf(mem),
            },
            .r2 = r2,
            .r3 = r3,
        },
        .foot = .{ .left = left, .right = right },
        .line_at = kill_at,
        .points = points.items,
        .raw = .{ .mem = mem, .procs = procs, .cpu_milli = cpu, .run_s = run },
    };
}

/// The colour a rising trend is written in: the card's own, if it is
/// warning; plain otherwise.
fn warnTone(t: Tone) ?Tone {
    return switch (t) {
        .warn1, .warn2, .warn3, .warn4, .withheld => t,
        else => null,
    };
}

fn gridOut(arena: Allocator, in: In) Allocator.Error!GridOut {
    const tr = in.tr;
    const g = in.grid;
    const day = g.span == .day;
    const n = g.span.cells();

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    // The group's terminals first, in the cards' order, then any that
    // closed; a terminal with no line in the grid has an empty row.
    for (in.panes) |p| try rows.append(arena, try rowOut(arena, in, p.id, p.name));
    for (g.rows) |r| {
        const listed = for (in.panes) |p| {
            if (p.id == r.pane) break true;
        } else false;
        if (listed) continue;
        const name = in.gone_name(in.gone_ctx, r.pane) orelse continue;
        try rows.append(arena, try rowOut(arena, in, r.pane, name));
    }

    var axis: std.ArrayListUnmanaged(@typeInfo(@FieldType(GridOut, "axis")).pointer.child) = .empty;
    if (day) {
        try axis.append(arena, .{ .cell = 0, .text = try fill(arena, tr(words.yesterday), &.{try clock(arena, g.start_ms, in.offset_ms)}) });
        // Every six hours on the clock.
        for (1..n - 1) |i| {
            const at = g.start_ms + @as(i64, @intCast(i)) * g.cellMs();
            if (@mod(at + in.offset_ms, 6 * 3600 * 1000) == 0) try axis.append(arena, .{ .cell = i, .text = try clock(arena, at, in.offset_ms) });
        }
    } else {
        // Each day's first cell: its date.
        var i: usize = 0;
        while (i < n) : (i += day_cells) try axis.append(arena, .{ .cell = i, .text = try date(arena, g.start_ms + @as(i64, @intCast(i)) * g.cellMs(), in.offset_ms) });
    }
    try axis.append(arena, .{ .cell = n - 1, .text = tr(words.now) });

    const Span = @typeInfo(@FieldType(GridOut, "spans")).pointer.child;
    const Legend = @typeInfo(@FieldType(GridOut, "legend")).pointer.child;
    return .{
        .span = g.span,
        .spans = try arena.dupe(Span, &.{ .{ .span = .day, .text = tr(words.span_day) }, .{ .span = .week, .text = tr(words.span_week) } }),
        .title = tr(if (day) words.title_day else words.title_week),
        .subtitle = tr(if (day) words.sub_day else words.sub_week),
        .legend = try arena.dupe(Legend, &.{
            .{ .tone = .none, .text = tr(words.legend_none) },
            .{ .tone = .ok, .text = tr(words.legend_ok) },
            .{ .tone = .warn1, .text = try fill(arena, tr(words.legend_warn), &.{"1"}) },
            .{ .tone = .warn2, .text = try fill(arena, tr(words.legend_warn), &.{"2"}) },
            .{ .tone = .killed, .text = tr(words.legend_killed) },
        }),
        .start_ms = g.start_ms,
        .cell_ms = g.cellMs(),
        .cells = n,
        .axis = axis.items,
        .panes = rows.items,
    };
}

fn rowOut(arena: Allocator, in: In, id: u64, name: []const u8) Allocator.Error!Row {
    const tr = in.tr;
    const g = in.grid;
    const n = g.span.cells();
    const tones = try arena.alloc(Tone, n);
    @memset(tones, .none);
    var hover: std.ArrayListUnmanaged(@typeInfo(@FieldType(Row, "hover")).pointer.child) = .empty;
    const row = for (g.rows) |r| {
        if (r.pane == id) break r;
    } else null;
    if (row) |r| for (r.cells, 0..) |cell, i| {
        tones[i] = toneOf(cell.level);
        if (cell.level == null) continue;
        const at = g.start_ms + @as(i64, @intCast(i)) * g.cellMs();
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        if (cell.mark) |mk| {
            const when = try clock(arena, mk.at_ms, in.offset_ms);
            try lines.append(arena, switch (mk.what) {
                .kill => .{ .tone = .killed, .text = try fill(arena, tr(words.tip_killed), &.{ when, name }) },
                .withheld => .{ .tone = .withheld, .text = try fill(arena, tr(words.tip_withheld), &.{ when, name }) },
                .warn => .{ .tone = toneOf(Level.ofWarn(mk.line - 1)), .text = try fill(arena, tr(words.tip_warn), &.{ when, name, try num(arena, mk.line) }) },
            });
            try lines.append(arena, .{ .tone = null, .text = try markDetail(arena, tr, mk) });
            if (mk.topName().len > 0) {
                var nm: [16]u8 = undefined;
                try lines.append(arena, .{ .tone = null, .text = try fill(arena, tr(words.tip_largest), &.{ judge.safeName(&nm, mk.topName()), try num(arena, mk.count) }) });
            }
            try lines.append(arena, .{ .tone = null, .text = tr(if (mk.told_person and mk.told_supervisor)
                words.tip_told_both
            else if (mk.told_supervisor)
                words.tip_told_supervisor
            else if (mk.told_person)
                words.tip_told_person
            else
                words.tip_told_none) });
        } else {
            try lines.append(arena, .{ .tone = toneOf(cell.level), .text = try fill(arena, tr(words.tip_peak), &.{ try clock(arena, at, in.offset_ms), name, try bytes(arena, cell.mem) }) });
        }
        try hover.append(arena, .{ .cell = i, .lines = lines.items });
    };
    return .{ .id = try hex(arena, id), .name = name, .cells = tones, .hover = hover.items };
}

fn markDetail(arena: Allocator, tr: Tr, mk: Grid.Mark) Allocator.Error![]const u8 {
    const secs = try num(arena, mk.for_ms / 1000);
    return switch (mk.metric) {
        .memory => switch (mk.what) {
            .warn => try fill(arena, tr(words.tip_memory_warn), &.{ try bytes(arena, mk.value), try bytes(arena, mk.at_line) }),
            else => if (mk.fast)
                try fill(arena, tr(words.tip_memory_fast), &.{ try bytes(arena, mk.value), try bytes(arena, mk.at_line) })
            else
                try fill(arena, tr(words.tip_memory_kill), &.{ try bytes(arena, mk.value), try bytes(arena, mk.at_line), secs }),
        },
        .processes => switch (mk.what) {
            .warn => try fill(arena, tr(words.tip_processes_warn), &.{ try num(arena, mk.value), try num(arena, mk.at_line) }),
            else => if (mk.fast)
                try fill(arena, tr(words.tip_processes_fast), &.{ try num(arena, mk.value), try num(arena, mk.at_line) })
            else
                try fill(arena, tr(words.tip_processes_kill), &.{ try num(arena, mk.value), try num(arena, mk.at_line), secs }),
        },
    };
}

// --------------------------------------------------------------- numbers

fn bytes(arena: Allocator, b: u64) Allocator.Error![]const u8 {
    var buf: [32]u8 = undefined;
    return arena.dupe(u8, judge.bytesText(&buf, b));
}

/// The number of `bytesText` without its unit: "14.1" of "14.1 GB".
fn gbNumber(arena: Allocator, b: u64) Allocator.Error![]const u8 {
    var buf: [32]u8 = undefined;
    const t = judge.bytesText(&buf, b);
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    return arena.dupe(u8, t[0..sp]);
}

/// The unit `gbNumber` left off, for a row with no line to be over.
fn unitOf(b: u64) []const u8 {
    return if (b >= 1 << 30) "GB" else "MB";
}

fn num(arena: Allocator, n: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn hex(arena: Allocator, id: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "0x{x}", .{id});
}

/// "6.1" of 6100 thousandths.
fn cores(arena: Allocator, milli: u32) Allocator.Error![]const u8 {
    const tenths = (milli + 50) / 100;
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

/// "1:12" of 4320 s.
fn hoursMinutes(arena: Allocator, secs: i64) Allocator.Error![]const u8 {
    const m: u64 = @intCast(@divFloor(@max(0, secs), 60));
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ m / 60, m % 60 });
}

/// "03:14" on the person's clock.
fn clock(arena: Allocator, at_ms: i64, offset_ms: i64) Allocator.Error![]const u8 {
    const day_ms: i64 = 24 * 3600 * 1000;
    const in_day = @mod(at_ms + offset_ms, day_ms);
    const mins: u64 = @intCast(@divFloor(in_day, 60_000));
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ mins / 60, mins % 60 });
}

/// "10/21" on the person's calendar.
fn date(arena: Allocator, at_ms: i64, offset_ms: i64) Allocator.Error![]const u8 {
    const days = @divFloor(at_ms + offset_ms, 24 * 3600 * 1000);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(days * 86400) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d}/{d}", .{ md.month.numeric(), md.day_index + 1 });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const gib: u64 = 1 << 30;
const mib: u64 = 1 << 20;
/// 2026-10-21 12:00 UTC: 20:00 at UTC+8.
const noon: i64 = 1792584000000;
const plus8: i64 = 8 * 3600 * 1000;

fn noName(_: *const anyopaque, _: u64) ?[]const u8 {
    return null;
}

fn goneNames(_: *const anyopaque, id: u64) ?[]const u8 {
    return if (id == 0xdead) "ocr-mask" else null;
}

fn lim(text: []const u8) !limits.Limits {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    var why: []const u8 = "";
    return limits.parse(v, &why);
}

/// Every reading two seconds apart for a minute, `step` more each.
fn climbing(r: *Recent, from: u64, step: u64) void {
    for (0..31) |i| r.push(.{ .seq = i + 1, .at_ms = noon - 60_000 + @as(i64, @intCast(i)) * 2000, .mem = from + i * step }, i * 2 * std.time.ns_per_s * 6, noon - 72 * 60_000);
}

const Got = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,

    fn deinit(self: *Got) void {
        self.arena.deinit();
    }

    fn card(self: *const Got, i: usize) std.json.ObjectMap {
        return self.root.object.get("cards").?.array.items[i].object;
    }
};

fn rendered(in: In) !Got {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    const json = try render(arena.allocator(), in);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    return .{ .arena = arena, .root = root };
}

fn str(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return o.get(key).?.string;
}

fn baseIn(panes: []const Pane, grid: *const Grid.Grid) In {
    return .{
        .group = "web-app",
        .seq = 31,
        .since = 0,
        .now_ms = noon,
        .offset_ms = plus8,
        .period_ms = 2000,
        .machine = .{ .used = 23900 * mib, .phys = 32 * gib, .swap = 1200 * mib, .pressure = 1 },
        .panes = panes,
        .grid = grid,
        .kills_24h = 1,
        .warns_24h = 6,
        .gone_name = noName,
        .gone_ctx = undefined,
        .tr = judge.english,
    };
}

test "2015: a card over its second warn line and climbing says how far, how fast, and when it reaches the line" {
    var r: Recent = .{};
    climbing(&r, 13 * gib, 20 * mib);
    const l = try lim("{\"memory\":{\"warn\":[\"8G\",\"13G\"],\"kill\":\"19G\"}}");
    var usage: ledger.Usage = .{ .id = 0x9a, .mem = r.newest().?.mem, .procs = 23 };
    usage.top_len = 0;
    const panes = [_]Pane{.{ .id = 0x9a, .name = "screenshot-diff", .role = .worker, .usage = usage, .lim = l, .level = .warn2, .recent = &r, .killed = null }};
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, "", &.{});
    defer grid.deinit(testing.allocator);
    var got = try rendered(baseIn(&panes, &grid));
    defer got.deinit();

    const c = got.card(0);
    try testing.expectEqualStrings("0x9a", str(c, "id"));
    try testing.expectEqualStrings("warn2", str(c, "tone"));
    try testing.expectEqualStrings("Warning 2", str(c.get("badge").?.object, "text"));
    try testing.expect(c.get("role").? == .null);
    const dial = c.get("dial").?.object;
    try testing.expectEqualStrings("Kill line 19.0 GB", str(dial, "cap"));
    try testing.expectEqualStrings("72", str(dial, "big"));
    try testing.expectEqual(@as(usize, 2), dial.get("ticks").?.array.items.len);
    const rows = c.get("lines").?.object;
    try testing.expectEqualStrings("13.6", str(rows.get("r1").?.object, "value"));
    try testing.expectEqualStrings("/ 19.0 GB", str(rows.get("r1").?.object, "rest"));
    try testing.expectEqualStrings("↗ +600 MB/min", str(rows.get("r2").?.object, "text"));
    try testing.expectEqualStrings("warn2", str(rows.get("r2").?.object, "tone"));
    // 5.4 GB to go at 0.6 GB a minute: 9.2 minutes, said as the tenth.
    try testing.expectEqualStrings("About 10 min to the line", str(rows.get("r3").?.object, "text"));
    const foot = c.get("foot").?.object;
    // 12 s of CPU every 2 s: six cores.
    try testing.expectEqualStrings("CPU 6.0 cores · 23 processes", str(foot, "left"));
    try testing.expectEqualStrings("Ran 1:12", str(foot, "right"));
    try testing.expectEqual(@as(usize, 31), c.get("points").?.array.items.len);
    try testing.expect(got.root.object.get("full").?.bool);

    // The machine line and the count line.
    const text = got.root.object.get("machine").?.object.get("text").?.object;
    try testing.expectEqualStrings("Machine", str(text, "label"));
    try testing.expectEqualStrings("23.3", str(text, "mem"));
    try testing.expectEqualStrings("/ 32.0 GB", str(text, "mem_of"));
    try testing.expectEqualStrings("Memory pressure normal", str(text, "pressure"));
    try testing.expectEqualStrings("In 24 hours: stopped 1 times · 6 warnings", str(text, "day"));
    try testing.expectEqualStrings("Now 1 terminals · 1 warning · 0 stopped", got.root.object.get("now_line").?.string);
}

test "2015: a stopped card says when, against what, and that the supervisor has the command" {
    var r: Recent = .{};
    climbing(&r, 0, 0);
    const l = try lim("{\"memory\":{\"kill\":\"19G\"}}");
    const usage: ledger.Usage = .{ .id = 0x5, .mem = 100 * mib, .procs = 2 };
    // 03:14 local: 19:14 UTC the day before noon.
    const at = noon - (20 * 60 - (3 * 60 + 14)) * 60_000 + 24 * 3600 * 1000 - 24 * 3600 * 1000;
    const stopped_at = noon - 5 * 60_000;
    _ = at;
    const panes = [_]Pane{.{ .id = 0x5, .name = "ocr-mask", .role = .worker, .usage = usage, .lim = l, .level = .ok, .recent = &r, .killed = .{ .at_ms = stopped_at, .metric = .memory, .value = 19866 * mib, .at = 19 * gib } }};
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, "", &.{});
    defer grid.deinit(testing.allocator);
    var got = try rendered(baseIn(&panes, &grid));
    defer got.deinit();
    const c = got.card(0);
    try testing.expectEqualStrings("killed", str(c, "tone"));
    try testing.expectEqualStrings("Stopped 19:55", str(c.get("badge").?.object, "text"));
    try testing.expectEqualStrings("102", str(c.get("dial").?.object, "big"));
    const rows = c.get("lines").?.object;
    try testing.expectEqualStrings("↓ Stopped", str(rows.get("r2").?.object, "text"));
    try testing.expectEqualStrings("Stopped at 19:55", str(rows.get("r3").?.object, "text"));
    try testing.expectEqualStrings("Resume command given to the supervisor", str(c.get("foot").?.object, "left"));
    try testing.expectEqualStrings("Now 1 terminals · 0 warning · 1 stopped", got.root.object.get("now_line").?.string);

    // Eleven minutes on, the card is itself again.
    var later = baseIn(&panes, &grid);
    later.now_ms = stopped_at + killed_shown_ms + 60_000;
    var got2 = try rendered(later);
    defer got2.deinit();
    try testing.expectEqualStrings("ok", str(got2.card(0), "tone"));
}

test "2015: a card with no kill line is measured against the machine, and a terminal of yours says so" {
    const usage: ledger.Usage = .{ .id = 0x7, .mem = 400 * mib, .procs = 2 };
    const panes = [_]Pane{.{ .id = 0x7, .name = "~/design-system", .role = .own, .usage = usage, .lim = .none, .level = .ok, .recent = null, .killed = null }};
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, "", &.{});
    defer grid.deinit(testing.allocator);
    var got = try rendered(baseIn(&panes, &grid));
    defer got.deinit();
    const c = got.card(0);
    try testing.expectEqualStrings("Your terminal", str(c, "role"));
    try testing.expectEqualStrings("ok", str(c, "tone"));
    try testing.expect(c.get("badge").? == .null);
    try testing.expectEqualStrings("Machine 32.0 GB", str(c.get("dial").?.object, "cap"));
    try testing.expectEqualStrings("1", str(c.get("dial").?.object, "big"));
    const rows = c.get("lines").?.object;
    try testing.expectEqualStrings("MB", str(rows.get("r1").?.object, "rest"));
    // No readings kept: no trend; no line: says so.
    try testing.expect(rows.get("r2").? == .null);
    try testing.expectEqualStrings("No kill line", str(rows.get("r3").?.object, "text"));
    try testing.expectEqualStrings("2 processes", str(c.get("foot").?.object, "left"));
    try testing.expectEqualStrings("", str(c.get("foot").?.object, "right"));
}

test "2015: the next ask has only the points after the last, and says it is not the whole" {
    var r: Recent = .{};
    climbing(&r, gib, mib);
    const usage: ledger.Usage = .{ .id = 0x1, .mem = gib, .procs = 1 };
    const panes = [_]Pane{.{ .id = 0x1, .name = "a", .role = .worker, .usage = usage, .lim = .none, .level = .ok, .recent = &r, .killed = null }};
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, "", &.{});
    defer grid.deinit(testing.allocator);
    var in = baseIn(&panes, &grid);
    in.since = 28;
    var got = try rendered(in);
    defer got.deinit();
    try testing.expect(!got.root.object.get("full").?.bool);
    const pts = got.card(0).get("points").?.array.items;
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(@as(i64, noon), pts[2].array.items[0].integer);
}

test "2015: a grid cell's hover says what stopped, why, the largest process and who was told; a closed terminal keeps its row" {
    var buf: [600]u8 = undefined;
    const kill_at = noon - 3 * 3600 * 1000 + 14 * 60_000;
    const line = try std.fmt.bufPrint(&buf, "{{\"t\":\"kill\",\"pane\":\"0xdead\",\"at\":{d},\"metric\":\"memory\",\"value\":20830591385,\"line\":\"kill\",\"at_line\":20401094656,\"for_ms\":10000,\"top\":\"python3.13\",\"count\":7,\"fast\":false,\"told_person\":true,\"told_supervisor\":true}}\n", .{kill_at});
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, line, &.{});
    defer grid.deinit(testing.allocator);
    const panes = [_]Pane{.{ .id = 0x1, .name = "a", .role = .supervisor, .usage = null, .lim = .none, .level = .ok, .recent = null, .killed = null }};
    var in = baseIn(&panes, &grid);
    in.gone_name = goneNames;
    var got = try rendered(in);
    defer got.deinit();
    const g = got.root.object.get("grid").?.object;
    try testing.expectEqual(@as(i64, 48), g.get("cells").?.integer);
    try testing.expectEqualStrings("24 hours", str(g.get("spans").?.array.items[0].object, "text"));
    const rows = g.get("panes").?.array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("a", str(rows[0].object, "name"));
    try testing.expectEqualStrings("ocr-mask", str(rows[1].object, "name"));
    const hover = rows[1].object.get("hover").?.array.items;
    try testing.expectEqual(@as(usize, 1), hover.len);
    const lines = hover[0].object.get("lines").?.array.items;
    try testing.expectEqualStrings("17:14  ocr-mask was stopped", str(lines[0].object, "text"));
    try testing.expectEqualStrings("killed", str(lines[0].object, "tone"));
    try testing.expectEqualStrings("Memory 19.4 GB, over the kill line 19.0 GB for 10 s", str(lines[1].object, "text"));
    try testing.expectEqualStrings("Largest: python3.13 ×7", str(lines[2].object, "text"));
    try testing.expectEqualStrings("You and the supervisor were told", str(lines[3].object, "text"));
    const cell: usize = @intCast(hover[0].object.get("cell").?.integer);
    try testing.expectEqualStrings("killed", rows[1].object.get("cells").?.array.items[cell].string);
    // The axis: yesterday's first half hour, the six-hourly marks, now.
    const axis = g.get("axis").?.array.items;
    try testing.expectEqualStrings("Yesterday 20:30", str(axis[0].object, "text"));
    try testing.expectEqualStrings("Now", str(axis[axis.len - 1].object, "text"));
    // A row for the supervisor's terminal with no readings: all absent.
    for (rows[0].object.get("cells").?.array.items) |t| try testing.expectEqualStrings("none", t.string);
}

test "2015: every sentence of the performance page is in po/zh_CN.po" {
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
        try testing.expect(said.len > 0);
    }
}
