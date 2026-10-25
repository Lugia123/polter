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
const ResourceNames = @import("ResourceNames.zig");
const TerminalMeta = @import("TerminalMeta.zig");
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
    /// Which rows are really one row: an agent session that has changed
    /// terminal ids (task 2234). Null is "nothing known": every terminal
    /// is a row of its own, which is what this page did before.
    sessions: ?Sessions = null,
    tr: Tr,
};

/// Which terminal ids are the same row (task 2234).
///
/// A terminal's id is drawn afresh every run, so one agent session that has
/// been `--resume`d three times is three ids and would be three rows -- six
/// of them in the group on this machine. The agent's own session id is what
/// says they are one, exactly as `Reclaim` says it for tasks and groups
/// (`Reclaim.keyOf`), and that is the key `of` hands back.
///
/// **The name of a merged row is the title read latest** (`Sessions.seen`,
/// which is the same rule `Reclaim` uses for which session a terminal ended
/// on): a terminal renamed mid-session must not put the row back to the
/// name it had when the session started.
pub const Sessions = struct {
    /// The same `key` for every terminal the same agent session ran in.
    key: *const fn (ctx: ?*anyopaque, id: u64) u64,
    /// When this terminal's name was last true; null when unknown, and
    /// then the row that came first keeps its name.
    seen: *const fn (ctx: ?*anyopaque, id: u64) ?i64,
    ctx: ?*anyopaque,
};

/// Which terminal ran which agent session, and the one place that decides
/// it (task 2234).
///
/// **A key of its own, not the id.** `keyOf` hands back the pane id itself
/// for a terminal no session is known for, so a plain shell is a row of its
/// own without a second table. A session's key is the hash of `<cli>` and
/// the session id, the same two things `Reclaim.keyOf` joins.
///
/// **Only the key is kept here.** The name and when it was last true are
/// `ResourceNames`' -- it already writes a title and a `seen_ms` per pane,
/// and a second copy here would be a second thing to keep true.
pub const SessionTable = struct {
    entries: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    pub fn deinit(self: *SessionTable, alloc: Allocator) void {
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// The terminal is running this agent session.
    pub fn note(self: *SessionTable, alloc: Allocator, id: u64, cli: []const u8, session_id: []const u8) void {
        if (session_id.len == 0) return;
        self.entries.put(alloc, id, sessionKey(cli, session_id)) catch {};
    }

    /// Fill from what earlier runs wrote down, once at startup: the agent
    /// session each terminal ended on (`TerminalMeta`). The last note for a
    /// terminal is the one that counts, as it is in `Reclaim`.
    pub fn seed(self: *SessionTable, alloc: Allocator, notes: []const TerminalMeta.Note) void {
        var at: std.AutoHashMapUnmanaged(u64, i64) = .empty;
        defer at.deinit(alloc);
        for (notes) |n| {
            if (n.kind != .agent or n.session_id.len == 0) continue;
            const last = at.get(n.terminal);
            if (last != null and last.? > n.at_ms) continue;
            at.put(alloc, n.terminal, n.at_ms) catch {};
            self.note(alloc, n.terminal, n.cli, n.session_id);
        }
    }

    /// The row this terminal belongs to: its session's key, or the
    /// terminal's own id when no session is known for it. Never zero, so
    /// that a row whose id could not be read (`idOf`) joins nobody.
    pub fn keyOf(self: *const SessionTable, id: u64) u64 {
        if (id == 0) return 0;
        return self.entries.get(id) orelse id;
    }

    /// Drop what `names` has forgotten (task 2234): a terminal that
    /// `ResourceNames.prune` has taken out can never name a row again, so
    /// its entry here is dead too. Without this the map only ever grows --
    /// one 16-byte entry per terminal that ever ran an agent, plus every
    /// one the startup `seed` reads out of `TerminalMeta`'s history.
    /// Called from the one place the other table is pruned (`App.
    /// keepResourceNames`), so the two are emptied together.
    pub fn prune(self: *SessionTable, names: *const ResourceNames) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (names.get(kv.key_ptr.*) != null) continue;
            self.entries.removeByPtr(kv.key_ptr);
        }
    }

    pub fn sessions(self: *const SessionTable) Sessions {
        return .{ .key = &of, .seen = &null_seen, .ctx = @constCast(self) };
    }

    fn of(ctx: ?*anyopaque, id: u64) u64 {
        const self: *const SessionTable = @ptrCast(@alignCast(ctx.?));
        return self.keyOf(id);
    }

    fn null_seen(_: ?*anyopaque, _: u64) ?i64 {
        return null;
    }
};

/// `<cli> NUL <session id>`, hashed: `Reclaim.keyOf`'s two halves, so the
/// two features answer "the same session" the same way.
pub fn sessionKey(cli: []const u8, session_id: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x2234);
    h.update(cli);
    h.update(&.{0});
    h.update(session_id);
    return h.final();
}

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

/// What one row says of one cell, when it has something to say.
const HoverNote = struct { cell: usize, lines: []const Line };

const Row = struct {
    id: []const u8,
    name: []const u8,
    cells: []const Tone,
    hover: []const HoverNote,

    /// What this row says of one cell, or null when it has no line for it.
    /// (`mergeSessions` needs this: a merged cell's lines must be the ones
    /// from the row whose reading set that cell's colour.)
    fn hoverFor(self: Row, cell: usize) ?HoverNote {
        for (self.hover) |h| if (h.cell == cell) return h;
        return null;
    }
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

    // One agent session, one row (task 2234): a terminal that came back
    // under a new id is the same row, and its strips are read as one.
    const listed = try mergeSessions(arena, in, rows.items);

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
        .panes = listed,
    };
}

fn rowOut(arena: Allocator, in: In, id: u64, name: []const u8) Allocator.Error!Row {
    const tr = in.tr;
    const g = in.grid;
    const n = g.span.cells();
    const tones = try arena.alloc(Tone, n);
    @memset(tones, .none);
    var hover: std.ArrayListUnmanaged(HoverNote) = .empty;
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

/// The rows of one agent session read as one row (task 2234).
///
/// Two terminals that ran the same session are the same terminal as far as
/// this page is concerned -- one agent, one line of history -- so their
/// strips are read as one: each cell takes the worse of what fell in it,
/// exactly as `ResourceGrid.raise` reads two readings of the *same* pane.
/// The name is the one read latest (`Sessions.seen`), which is `Reclaim`'s
/// rule for which session a terminal ended on.
///
/// With no `sessions` the list comes back exactly as it was, so a caller
/// that knows nothing about agent sessions draws what it drew before.
fn mergeSessions(arena: Allocator, in: In, rows: []const Row) Allocator.Error![]const Row {
    const s = in.sessions orelse return rows;
    var out: std.ArrayListUnmanaged(Row) = .empty;

    // The newest name per key, and which row wears it.
    const Newest = struct { name: []const u8, at: i64, id: []const u8 };
    var newest: std.AutoHashMapUnmanaged(u64, Newest) = .empty;
    for (rows) |r| {
        const id = idOf(r.id);
        const key = rowKey(s, r.id, id);
        const at = s.seen(s.ctx, id) orelse -1;
        const gop = try newest.getOrPut(arena, key);
        // The latest name wins; a tie goes to the row that came first --
        // and `in.panes` come first, so a terminal that is here now is
        // named after itself rather than after the run before it.
        if (!gop.found_existing or at > gop.value_ptr.at) gop.value_ptr.* = .{ .name = r.name, .at = at, .id = r.id };
    }

    // The keys seen, in the order their first row came: the order the
    // cards and the history are already in.
    var order: std.ArrayListUnmanaged(u64) = .empty;
    for (rows) |r| {
        const key = rowKey(s, r.id, idOf(r.id));
        if (contains(order.items, key)) continue;
        try order.append(arena, key);
    }

    for (order.items) |key| {
        var cells: []Tone = &.{};
        // Which row each cell's colour came from, by index into `rows`.
        var from: std.ArrayListUnmanaged(usize) = .empty;
        for (rows, 0..) |r, i| {
            if (rowKey(s, r.id, idOf(r.id)) != key) continue;
            if (cells.len == 0) {
                cells = try arena.dupe(Tone, r.cells);
                try from.appendNTimes(arena, i, cells.len);
            } else for (r.cells, 0..) |t, c| {
                if (@intFromEnum(t) > @intFromEnum(cells[c])) {
                    cells[c] = t;
                    from.items[c] = i;
                }
            }
        }
        // The hover follows the colour it sits on (task 2234, the
        // reviewer's third note): a cell's lines are the ones from the row
        // whose reading set that cell's tone. The first row that has a line
        // for the cell is the fallback, for a cell whose winner has none.
        var cells_with_hover: std.ArrayListUnmanaged(usize) = .empty;
        for (rows) |r| for (r.hover) |h| {
            const already = for (cells_with_hover.items) |c| {
                if (c == h.cell) break true;
            } else false;
            if (!already) try cells_with_hover.append(arena, h.cell);
        };
        var hover: std.ArrayListUnmanaged(HoverNote) = .empty;
        for (cells_with_hover.items) |cell| {
            const want = rows[from.items[cell]].hoverFor(cell);
            const fallback = for (rows) |r| {
                if (r.hoverFor(cell)) |h| break h;
            } else null;
            if (want orelse fallback) |h| try hover.append(arena, h);
        }
        const win = newest.get(key).?;
        try out.append(arena, .{ .id = win.id, .name = win.name, .cells = cells, .hover = hover.items });
    }
    return out.items;
}

/// The row a row's id belongs to. A row whose id could not be read is not
/// folded in with every other unreadable one -- it is keyed by its own
/// text, so two of them stay two rows.
fn rowKey(s: Sessions, text: []const u8, id: u64) u64 {
    if (id != 0) return s.key(s.ctx, id);
    return std.hash.Wyhash.hash(0x2234, text) | 1;
}

fn contains(keys: []const u64, key: u64) bool {
    for (keys) |k| if (k == key) return true;
    return false;
}

/// The terminal id a row's `id` string was made from (`hex`, which writes
/// `"0x11"`; base 0 reads the prefix). ⚠️ `parseUnsigned(.., 16)` is **not**
/// that: it refuses the `0x` and answers `error.InvalidCharacter`, so every
/// row would read 0 -- which is exactly what the first cut of this did, and
/// every id then joined every other id's session.
///
/// A row whose id is not an id at all gets 0, which `keyOf` keeps out of
/// every session's key: its own row, joining nobody.
fn idOf(text: []const u8) u64 {
    return std.fmt.parseInt(u64, text, 0) catch 0;
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

test "2234: a session that came back under three terminal ids is one row, its three stretches read as one" {
    // The same agent session, three runs, three ids -- and the newest id
    // is the one the row is named after.
    var table: SessionTable = .{};
    defer table.deinit(testing.allocator);
    for ([_]u64{ 0x11, 0x22, 0x33 }) |id| table.note(testing.allocator, id, "claude-code", "a66ecf7c-0000-4000-8000-000000000001");

    // Three stretches of the day, each from a different id: 12:00, 14:00
    // and 16:00 local (04:00, 06:00 and 08:00 UTC). The 24-hour grid runs
    // from 20:30 the evening before, so those are cells 31, 35 and 39.
    var buf: [3][200]u8 = undefined;
    const ids = [_]u64{ 0x11, 0x22, 0x33 };
    const levels = [_][]const u8{ "ok", "warn1", "warn2" };
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (ids, levels, 0..) |id, level, i| {
        const at = noon - (8 - @as(i64, @intCast(i)) * 2) * 3600 * 1000;
        const line = try std.fmt.bufPrint(&buf[i], "{{\"t\":\"slot\",\"pane\":\"0x{x}\",\"at\":{d},\"level\":\"{s}\",\"mem\":{d},\"procs\":1}}\n", .{ id, at, level, @as(u64, 1 + i) * gib });
        try text.appendSlice(testing.allocator, line);
    }
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, text.items, &.{});
    defer grid.deinit(testing.allocator);

    // 0x33 is the one running the session now; the other two are closed
    // terminals whose names are still written down.
    const panes = [_]Pane{.{ .id = 0x33, .name = "◐ Polter", .role = .worker, .usage = null, .lim = .none, .level = .ok, .recent = null, .killed = null }};
    var in = baseIn(&panes, &grid);
    in.gone_name = sessionGone;
    in.sessions = table.sessions();
    var got = try rendered(in);
    defer got.deinit();

    const rows = got.root.object.get("grid").?.object.get("panes").?.array.items;
    // **One row, not three.** Without the merge this is 3.
    try testing.expectEqual(@as(usize, 1), rows.len);
    // It wears the newest id and the name that terminal has now.
    try testing.expectEqualStrings("0x33", str(rows[0].object, "id"));
    try testing.expectEqualStrings("◐ Polter", str(rows[0].object, "name"));
    // The three stretches are in the one strip, each at its own hour.
    const cells = rows[0].object.get("cells").?.array.items;
    try testing.expectEqual(@as(usize, 48), cells.len);
    try testing.expectEqualStrings("none", cells[30].string);
    try testing.expectEqualStrings("ok", cells[31].string);
    try testing.expectEqualStrings("none", cells[34].string);
    try testing.expectEqualStrings("warn1", cells[35].string);
    try testing.expectEqualStrings("none", cells[38].string);
    try testing.expectEqualStrings("warn2", cells[39].string);
}

/// The names of the closed terminals in the test above.
fn sessionGone(_: *const anyopaque, id: u64) ?[]const u8 {
    return switch (id) {
        0x11 => "first run",
        0x22 => "second run",
        else => null,
    };
}

// Two terminals that ran one session, one that ran another, and a shell
// that ran none: **three** rows. The test above cannot say this -- one
// session is all it has, so a `mergeSessions` that folded *different*
// sessions together would read the same there (task 2234, the reviewer's
// first note). Here the wrong merge has nowhere to hide: too few rows
// means two sessions were read as one, too many means one session was read
// as two.
test "2234: two sessions and a shell are three rows, each row's own stretches in it" {
    var table: SessionTable = .{};
    defer table.deinit(testing.allocator);
    for ([_]u64{ 0x11, 0x22 }) |id| table.note(testing.allocator, id, "claude-code", "a66ecf7c-0000-4000-8000-00000000000a");
    table.note(testing.allocator, 0x33, "claude-code", "a66ecf7c-0000-4000-8000-00000000000b");
    // 0x44 is a plain shell: no session, so a row of its own.

    // One stretch each, at 12:00, 14:00, 16:00 and 18:00 local -- cells 31,
    // 35, 39 and 43 of the 24-hour grid (see the test above).
    const ids = [_]u64{ 0x11, 0x22, 0x33, 0x44 };
    const levels = [_][]const u8{ "ok", "warn1", "warn2", "ok" };
    var buf: [4][200]u8 = undefined;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (ids, levels, 0..) |id, level, i| {
        const at = noon - (8 - @as(i64, @intCast(i)) * 2) * 3600 * 1000;
        const line = try std.fmt.bufPrint(&buf[i], "{{\"t\":\"slot\",\"pane\":\"0x{x}\",\"at\":{d},\"level\":\"{s}\",\"mem\":{d},\"procs\":1}}\n", .{ id, at, level, @as(u64, 1 + i) * gib });
        try text.appendSlice(testing.allocator, line);
    }
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, text.items, &.{});
    defer grid.deinit(testing.allocator);

    // The session's latest run and the shell are open now; the two earlier
    // runs are closed terminals whose names are still written down.
    const panes = [_]Pane{
        .{ .id = 0x33, .name = "B one", .role = .worker, .usage = null, .lim = .none, .level = .ok, .recent = null, .killed = null },
        .{ .id = 0x44, .name = "shell", .role = .worker, .usage = null, .lim = .none, .level = .ok, .recent = null, .killed = null },
    };
    var in = baseIn(&panes, &grid);
    in.gone_name = sessionGone;
    in.sessions = table.sessions();
    var got = try rendered(in);
    defer got.deinit();

    const rows = got.root.object.get("grid").?.object.get("panes").?.array.items;
    // **Three rows**: the two runs of one session are one row, the other
    // session is another, and the shell is a third. Four would be the
    // page before task 2234; one or two means two sessions were folded
    // together, which the test above cannot see.
    try testing.expectEqual(@as(usize, 3), rows.len);

    const cells = struct {
        fn of(row: std.json.Value) []std.json.Value {
            return row.object.get("cells").?.array.items;
        }
    }.of;

    // The session that came back: one row, both of its stretches in it, and
    // nothing of anybody else's.
    try testing.expectEqualStrings("0x11", str(rows[2].object, "id"));
    try testing.expectEqualStrings("first run", str(rows[2].object, "name"));
    try testing.expectEqualStrings("none", cells(rows[2])[30].string);
    try testing.expectEqualStrings("ok", cells(rows[2])[31].string);
    try testing.expectEqualStrings("none", cells(rows[2])[34].string);
    try testing.expectEqualStrings("warn1", cells(rows[2])[35].string);
    try testing.expectEqualStrings("none", cells(rows[2])[39].string);
    try testing.expectEqualStrings("none", cells(rows[2])[43].string);

    // The other session keeps its own stretch, and only it.
    try testing.expectEqualStrings("0x33", str(rows[0].object, "id"));
    try testing.expectEqualStrings("B one", str(rows[0].object, "name"));
    try testing.expectEqualStrings("none", cells(rows[0])[31].string);
    try testing.expectEqualStrings("none", cells(rows[0])[35].string);
    try testing.expectEqualStrings("warn2", cells(rows[0])[39].string);
    try testing.expectEqualStrings("none", cells(rows[0])[43].string);

    // And the shell with no session is a row of its own, joined to nobody.
    try testing.expectEqualStrings("0x44", str(rows[1].object, "id"));
    try testing.expectEqualStrings("shell", str(rows[1].object, "name"));
    try testing.expectEqualStrings("none", cells(rows[1])[31].string);
    try testing.expectEqualStrings("none", cells(rows[1])[39].string);
    try testing.expectEqualStrings("ok", cells(rows[1])[43].string);
}

test "2234: a row's id is read out of its hex text, so two rows are not folded together" {
    // `hex` writes "0x11". Reading that back with base 16 refuses the
    // prefix and answers 0 for **every** row -- and then every row is one
    // row. This is the reading that tells the two apart, and it is here
    // because the test above cannot: with `sessions` nil nothing is
    // merged, so the mistake shows nowhere there.
    try testing.expectEqual(@as(u64, 0x11), idOf("0x11"));
    try testing.expectEqual(@as(u64, 0xdead), idOf("0xdead"));
    try testing.expectEqual(@as(u64, 0), idOf("not an id"));
    try testing.expectEqual(@as(u64, 0), idOf(""));
    // Two different rows must not come out with the same key.
    var table: SessionTable = .{};
    defer table.deinit(testing.allocator);
    const s = table.sessions();
    try testing.expect(rowKey(s, "0x11", idOf("0x11")) != rowKey(s, "0x22", idOf("0x22")));
    // And a row whose id could not be read joins nobody's session: it is
    // keyed by its own text, not by the 0 every unreadable id gives.
    try testing.expect(rowKey(s, "junk", idOf("junk")) != rowKey(s, "rubbish", idOf("rubbish")));
}

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

/// `key` of `o`, which must be there and hold null.
fn expectNull(o: std.json.ObjectMap, key: []const u8) !void {    const v = o.get(key) orelse {
        std.debug.print("{s} is missing; it should be there as null\n", .{key});
        return error.TestExpectedEqual;
    };
    try testing.expect(v == .null);
}

test "2015: a field the core has no value for is there, as null -- never left out" {
    // Windows reads no swap; a machine may not say its pressure. A host
    // that finds the key holding null draws nothing there (API.md §2.0).
    const usage: ledger.Usage = .{ .id = 0x7, .mem = 400 * mib, .procs = 2 };
    const panes = [_]Pane{.{ .id = 0x7, .name = "a", .role = .worker, .usage = usage, .lim = .none, .level = .ok, .recent = null, .killed = null }};
    var grid = try Grid.build(testing.allocator, .day, noon, plus8, "", &.{});
    defer grid.deinit(testing.allocator);
    var in = baseIn(&panes, &grid);
    in.machine = .{ .used = null, .phys = null, .swap = null, .pressure = null };
    var got = try rendered(in);
    defer got.deinit();
    const machine = got.root.object.get("machine").?.object;
    try expectNull(machine, "pressure_tone");
    const text = machine.get("text").?.object;
    for ([_][]const u8{ "mem", "mem_of", "swap", "pressure" }) |key| try expectNull(text, key);
    const c = got.card(0);
    try expectNull(c, "role");
    try expectNull(c, "badge");
    try expectNull(c, "line_at");
    try expectNull(c.get("lines").?.object, "r2");
    const raw = c.get("raw").?.object;
    try expectNull(raw, "cpu_milli");
    try expectNull(raw, "run_s");
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
