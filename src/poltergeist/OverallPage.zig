//! `resource_overview`'s answer (task 2149, handoff §5): everything a
//! supervisor needs to answer "what is Polter itself doing, and is this
//! machine running out" in one reply.
//!
//! Pure: what the app has gathered in, the JSON out. The app gathers
//! (`App.overallReport`); this only says -- the same split `ResourcePage`
//! and `TaskPage` have, and for the same reason: neither host and no caller
//! works out a slope or decides what "rising" means
//! (`tools/control-room-hosts-do-not-decide.py`).
//!
//! Every process carries `kind`, `pid`, `group`, `mem_mib` and `growth`
//! (`slope_mib_per_h` is the figure to quote): the minimum a supervisor is
//! looking for when something is eating the machine overnight. `last_24h`
//! comes with them, and the 1440 points only when one process was asked
//! for -- a reply nobody reads is a reply that costs somebody context.

const OverallPage = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Overall = @import("Overall.zig");

/// One group's tasks and record, which are the core's own numbers rather
/// than any process's (handoff §1).
///
/// **Plus the three parts of its terminals**, which the app knows from the
/// per-terminal reading and this file cannot: the group page's segment bar
/// is four widths in MiB (`parts`), and a bar is not something a host can
/// add up for itself without deciding what a supervisor is
/// (`tools/control-room-hosts-do-not-decide.py`).
pub const GroupFacts = struct {
    group: []const u8,
    tasks: u32 = 0,
    tasks_open: u32 = 0,
    /// Bytes of the group's record on disk.
    record_bytes: u64 = 0,
    /// The group's supervisor terminal's tree, MiB.
    supervisor_mib: u64 = 0,
    /// Every other working terminal in it, MiB.
    workers_mib: u64 = 0,
    /// The person's own terminals in it, MiB.
    yours_mib: u64 = 0,
};

/// What the caller gathered: the reading, and what the core knows that the
/// process table does not.
pub const In = struct {
    /// Wall clock, milliseconds.
    now_ms: i64,
    offset_ms: i64,
    /// The machine's total memory, for the header.
    mem_total: ?u64 = null,
    /// Each group's tasks and record, for the `own` block.
    groups: []const GroupFacts = &.{},
    /// A terminal's group, by the row's pane id: a sidecar serves the
    /// terminal it is in, and that is the group it belongs to.
    groupOfPane: *const fn (ctx: ?*const anyopaque, pane: u64) []const u8 = noGroup,
    ctx: ?*const anyopaque = null,
    /// `{ "group": … }`: only that group's processes. Empty is all.
    only_group: []const u8 = "",
    /// `{ "pid": … }`: only that process, and its 24 hours of points.
    /// Zero is all.
    only_pid: u32 = 0,
};

fn noGroup(_: ?*const anyopaque, _: u64) []const u8 {
    return "";
}

const mib: u64 = 1 << 20;

/// The overall view's three stacked layers are read at a cell each: 288
/// cells over the 24-hour span (five minutes), 336 over the week (half an
/// hour).
///
/// **A cell count, not the ring's own.** The hour ring is 1440 points and
/// the week ring 1008; handing a chart every point would be tens of
/// thousands of numbers in one reply, and the figure drawn at 5 minutes is
/// not different from the one at 1. The choice is ours because it is what
/// the chart is *of*: a host that picked its own would be deciding how much
/// of the history is real (`tools/control-room-hosts-do-not-decide.py`).
const hour_cells = 288;
const hour_cell_s: u32 = 300;
const week_cells = 336;
const week_cell_s: u32 = 1800;

/// The reply, typed, so that the shape is the declaration and neither a
/// missing field nor a stray comma can be a bug of its own. Serialized with
/// `Stringify`, as the performance page's answer is.
const Out = struct {
    at: []const u8,
    machine: Machine,
    polter: Polter,
    groups: []const Group,
};

const Machine = struct {
    mem_total_mib: ?u64,
    mem_used_mib: ?u64,
    swap_used_mib: ?u64,
    swap_total_mib: ?u64,
    swap_growth: Growth,
    disk_free_mib: ?u64,
    disk_low: bool,
    disk_low_line_mib: u64,
    /// The machine's own two curves (handoff §6's small charts): swap, and
    /// free space on the startup disk -- which is what the 15 GB line is
    /// drawn against, so it is free space and not used.
    swap_hour: []const [2]u32,
    disk_hour: []const [2]u32,
};

const Growth = struct {
    rising: bool,
    slope_mib_per_h: i32,
    /// How much the window gained, MiB. The whole answer's `growth` blocks
    /// carry it, so a card can say "one hour +1.3 GB" without arithmetic.
    rose_mib: u32,
    /// Seconds since Polter started; null when it is not rising.
    since_s: ?u32,
    /// The same moment as a clock time on the reader's own clock
    /// (`2026-10-23T16:10:00+08:00`), because "since 57840" is a number
    /// nobody converts by hand (handoff §5).
    since: ?[]const u8,
};

const Polter = struct {
    total_mib: u64,
    /// Tenths of a core, all of Polter's rows together.
    cpu_ds: u32,
    /// The same as "2.6", which is how the card writes it.
    cpu_cores: []const u8,
    monitor_bytes: u64,
    processes: []const Row,
    /// Readings that had no row to go in, so "another N are not tracked" is
    /// answerable rather than silent.
    untracked: u32,
    /// When Polter started, on the reader's clock: `since_s` counts from
    /// here and the chart's x-axis begins here.
    run_started: []const u8,
    /// The three stacked layers, a series each, for the 24-hour span and
    /// the week. This is what the overall view's chart draws, and neither
    /// the week ring nor the category totals had any way out of the core
    /// before it (task 2149's review, #9).
    series: struct {
        hour: []const Layer,
        week: []const Layer,
        /// The step between cells, seconds: the host places a point, it
        /// does not choose the resolution.
        hour_step_s: u32,
        week_step_s: u32,
    },
};

const Layer = struct {
    /// One of `Overall.Category`, in the order the stack is drawn.
    kind: []const u8,
    /// MiB per cell, oldest first.
    cells: []const u32,
};

const Row = struct {
    kind: []const u8,
    pid: u32,
    /// Null for the main process and the monitor, which are in no group.
    group: ?[]const u8,
    /// How many processes are behind this row: one, except a sidecar row,
    /// which may be several `polter +mcp` processes.
    count: u32,
    mem_mib: u32,
    /// Tenths of a core, over the last interval that could be measured.
    cpu_ds: u32,
    growth: Growth,
    last_24h: Summary,
    /// **Whether the reading in front of the reader still names it.** A row
    /// nothing names is kept for 24 hours so the morning shows what died
    /// overnight; without this the reader takes a process that stopped at
    /// 03:00 for one that is running now (task 2149's review, #9).
    alive: bool,
    /// When it stopped being named, on the reader's clock; null while it is
    /// alive.
    died_at: ?[]const u8,
    /// When the process behind the row started; null for a row that is
    /// several processes (a sidecar) or a platform that does not say.
    started: ?[]const u8,
    /// The terminal this row is, for a sidecar whose row is a terminal's.
    terminal: ?[]const u8,
    /// The sentence beside the monitor's row: it is a couple of MiB inside
    /// the main process's, already counted there.
    ///
    /// ⚠️ **An English sentence, not a msgid, and deliberately so for now.**
    /// The words of this page are slice 2's (`OverallPage` is not in
    /// `GhosttyI18n.zig`'s extractor list, so a marked word here would be
    /// in no catalogue); the field exists now because §5 asks for it. Slice
    /// 2 moves it to `i18n.N_`, adds the file to the extractor, and puts the
    /// words in `po/`.
    note: ?[]const u8 = null,
    /// Only when one process was asked for: 1440 points is a reply nobody
    /// reads, and asking for a process is saying you want them.
    points: ?[]const [2]u32 = null,
};

const Summary = struct {
    min_mib: u32,
    max_mib: u32,
    avg_mib: u32,
    samples: u32,
    /// What it held when the 24 hours began, so a card can say "16 hours ago
    /// it was 0.6 GB" (handoff §5).
    first_mib: ?u32,
    /// How many of the last 24 hours it was rising in, by the same rules
    /// every other verdict uses.
    rising_hours: u32,
};

const Group = struct {
    group: []const u8,
    /// The four parts, which sum to `total_mib` -- the segment bar's widths.
    total_mib: u64,
    parts: Parts,
    own: Own,
};

const Parts = struct {
    supervisor_mib: u64,
    workers_mib: u64,
    yours_mib: u64,
    /// The group's embedded chat, which is the group's own and no terminal
    /// of anybody's.
    own_mib: u64,
};

const Own = struct {
    /// The row behind the chat, so clicking the card can point at a
    /// process; null when the group has no chat running.
    chat_pid: ?u32,
    chat_mib: u64,
    /// The chat's own curve, weighed like every other row's: the card turns
    /// orange on it.
    growth: Growth,
    tasks: u32,
    tasks_open: u32,
    record_bytes: u64,
};

/// The monitor's row's sentence (see `Row.note`).
const monitor_note = "inside the main process, already counted there";

/// The whole answer, in `arena`.
pub fn render(arena: Allocator, overall: *const Overall, in: In) Allocator.Error![]u8 {
    const swap = overall.swapGrowth();
    const rows = try rowsOf(arena, overall, in);
    const groups = try groupsOf(arena, overall, in);

    var cpu_ds: u32 = 0;
    {
        var i: usize = 0;
        while (i < overall.tracked) : (i += 1) {
            const t = overall.slotAt(@intCast(i));
            if (!t.used or t.kind == .monitor) continue;
            cpu_ds +|= t.cpu_ds;
        }
    }
    const out: Out = .{
        .at = try isoOf(arena, in.now_ms, in.offset_ms),
        .machine = .{
            .mem_total_mib = try mibOf(in.mem_total),
            .mem_used_mib = try mibOf(overall.machine.mem_used),
            .swap_used_mib = try mibOf(overall.machine.swap_used),
            .swap_total_mib = try mibOf(overall.machine.swap_total),
            // The machine's swap is read by the same function a process is,
            // and weighed by the machine's own threshold (handoff §4).
            .swap_growth = try growthOut(arena, overall, in, swap, swap.rose_mib >= Overall.thresholds.swap_rising_mib),
            .disk_free_mib = try mibOf(overall.machine.disk_free),
            .disk_low = overall.diskLow(),
            .disk_low_line_mib = Overall.thresholds.disk_low_mib,
            .swap_hour = try pairsOf(arena, overall, .swap, .hour, hour_cells, hour_cell_s),
            .disk_hour = try pairsOf(arena, overall, .disk, .hour, hour_cells, hour_cell_s),
        },
        .polter = .{
            .total_mib = overall.totalMib(),
            .cpu_ds = cpu_ds,
            .cpu_cores = try tenths(arena, cpu_ds),
            .monitor_bytes = overall.monitorBytes(),
            .processes = rows,
            .untracked = overall.untracked,
            .run_started = try isoOf(arena, overall.run_start_ms, in.offset_ms),
            .series = .{
                .hour = try layers(arena, overall, .hour, hour_cells, hour_cell_s),
                .week = try layers(arena, overall, .week, week_cells, week_cell_s),
                .hour_step_s = hour_cell_s,
                .week_step_s = week_cell_s,
            },
        },
        .groups = groups,
    };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

/// The three layers, in the order the stack is drawn.
fn layers(arena: Allocator, overall: *const Overall, span: Overall.Span, cells: usize, step_s: u32) Allocator.Error![]const Layer {
    const cats = [_]Overall.Category{ .main, .chats, .sidecars };
    const out = try arena.alloc(Layer, cats.len);
    for (cats, out) |cat, *l| {
        const buf = try arena.alloc(u32, cells);
        overall.categorySeries(cat, span, step_s, buf);
        l.* = .{ .kind = @tagName(cat), .cells = buf };
    }
    return out;
}

/// One of the machine's own curves, as `[second, value]` pairs.
fn pairsOf(arena: Allocator, overall: *const Overall, which: Overall.MachineSeries, span: Overall.Span, cells: usize, step_s: u32) Allocator.Error![]const [2]u32 {
    const buf = try arena.alloc(u32, cells);
    overall.machineSeries(which, span, step_s, buf);
    // The cells are the same time base as the layers', so the host draws
    // the four charts against one axis.
    const out = try arena.alloc([2]u32, cells);
    const newest = overall.newestAtS();
    for (buf, out, 0..) |v, *p, i| {
        const back: u32 = @intCast(cells - 1 - i);
        p.* = .{ newest -| back *| step_s, v };
    }
    return out;
}

fn growthOut(arena: Allocator, overall: *const Overall, in: In, g: Overall.Growth, rising: bool) Allocator.Error!Growth {
    const ris = rising and g.rising;
    return .{
        .rising = ris,
        .slope_mib_per_h = g.slope_mib_per_h,
        .rose_mib = g.rose_mib,
        .since_s = g.since_s,
        .since = if (ris and g.since_s != null)
            try isoOf(arena, overall.run_start_ms + @as(i64, g.since_s.?) * 1000, in.offset_ms)
        else
            null,
    };
}

fn mibOf(bytes: ?u64) Allocator.Error!?u64 {
    const b = bytes orelse return null;
    return b / mib;
}

/// Every row the caller asked for, in the reading's order.
fn rowsOf(arena: Allocator, overall: *const Overall, in: In) Allocator.Error![]const Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    var i: usize = 0;
    while (i < overall.tracked) : (i += 1) {
        const t = overall.slotAt(@intCast(i));
        if (!t.used) continue;
        const group: ?[]const u8 = switch (t.kind) {
            .main, .monitor => null,
            .chat => t.groupName(),
            .sidecar => in.groupOfPane(in.ctx, t.pane),
        };
        // A group was named and this is not it. The main process and the
        // monitor belong to no group, so naming a group leaves them out.
        if (in.only_group.len > 0) {
            if (group == null) continue;
            if (!std.mem.eql(u8, group.?, in.only_group)) continue;
        }
        if (in.only_pid != 0 and t.pid != in.only_pid) continue;

        var points: ?[]const [2]u32 = null;
        if (in.only_pid != 0) points = try pointsOf(arena, overall, @intCast(i));
        const sum = overall.summarize(@intCast(i));
        try out.append(arena, .{
            .kind = @tagName(t.kind),
            .pid = t.pid,
            .group = group,
            .count = t.count,
            .mem_mib = t.mem_mib,
            .cpu_ds = t.cpu_ds,
            .growth = try growthOut(arena, overall, in, overall.growthOf(@intCast(i)), true),
            .last_24h = .{
                .min_mib = sum.min_mib,
                .max_mib = sum.max_mib,
                .avg_mib = sum.avg_mib,
                .samples = sum.samples,
                .first_mib = overall.firstMib(@intCast(i)),
                .rising_hours = overall.risingHours(@intCast(i)),
            },
            .alive = t.alive,
            // Stamped the first reading that did not name it, so the clock
            // is when it went, not when the reader looked (handoff §5's
            // "died at").
            .died_at = if (t.alive or t.died_ms == 0) null else try isoOf(arena, t.died_ms, in.offset_ms),
            // Zero for a row that is several processes (a sidecar) or a
            // platform that does not say, which is "not known" and not the
            // epoch.
            .started = if (t.start_ms == 0) null else try isoOf(arena, t.start_ms, in.offset_ms),
            .terminal = if (t.kind == .sidecar or t.kind == .chat) try hexOf(arena, t.pane) else null,
            .note = if (t.kind == .monitor) monitor_note else null,
            .points = points,
        });
    }
    return out.toOwnedSlice(arena);
}

/// A terminal id as the rest of the control room writes one.
fn hexOf(arena: Allocator, id: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "0x{x}", .{id});
}

/// Tenths of a core as "2.6", the way the card writes it.
fn tenths(arena: Allocator, ds: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ ds / 10, ds % 10 });
}

fn pointsOf(arena: Allocator, overall: *const Overall, i: u8) Allocator.Error![]const [2]u32 {
    var buf: [Overall.hour_cap]Overall.Point = undefined;
    const n = overall.hourPoints(i, &buf);
    const out = try arena.alloc([2]u32, n);
    for (buf[0..n], out) |p, *pair| pair.* = .{ p.at_s, p.mem_mib };
    return out;
}

/// Each group's own cost, and the core's numbers that no process table
/// holds.
///
/// **The four parts and the total come from one walk.** `total_mib` is what
/// the segment bar is drawn to, and the bar's four widths have to add up to
/// it -- computed apart they would differ by a rounding of somebody's
/// memory, and the reader would see a bar whose pieces do not fill it.
fn groupsOf(arena: Allocator, overall: *const Overall, in: In) Allocator.Error![]const Group {
    var out: std.ArrayListUnmanaged(Group) = .empty;
    for (in.groups) |g| {
        if (in.only_group.len > 0 and !std.mem.eql(u8, g.group, in.only_group)) continue;
        const chat = chatRow(overall, g.group);
        const own_mib: u64 = if (chat) |c| overall.slotAt(c).mem_mib else 0;
        // **The terminals' part is the group's whole tree, which the core
        // already worked out per terminal** (`GroupFacts`): a host that
        // added up rows itself would be deciding what a supervisor is.
        //
        // **And the group's sidecars are already inside it.** The
        // per-terminal reading (`ledger`) counts a pane's whole tree, the
        // `polter +mcp` processes in it among them; `Overall` is the one
        // that splits a sidecar out into a row of its own. Adding the
        // sidecar rows here would count them twice, and the four widths
        // would then over-fill the bar they are drawn as -- the mock's
        // numbers add up exactly (1.1 + 29.7 + 0.4 + 0.3 = 31.5), and the
        // reader compares the pieces with the total.
        const terminals = g.supervisor_mib + g.workers_mib + g.yours_mib;
        try out.append(arena, .{
            .group = g.group,
            .total_mib = terminals + own_mib,
            .parts = .{
                .supervisor_mib = g.supervisor_mib,
                .workers_mib = g.workers_mib,
                .yours_mib = g.yours_mib,
                .own_mib = own_mib,
            },
            .own = .{
                .chat_pid = if (chat) |c| overall.slotAt(c).pid else null,
                .chat_mib = own_mib,
                .growth = if (chat) |c|
                    try growthOut(arena, overall, in, overall.growthOf(c), true)
                else
                    emptyGrowth,
                .tasks = g.tasks,
                .tasks_open = g.tasks_open,
                .record_bytes = g.record_bytes,
            },
        });
    }
    return out.toOwnedSlice(arena);
}

const emptyGrowth: Growth = .{ .rising = false, .slope_mib_per_h = 0, .rose_mib = 0, .since_s = null, .since = null };

/// The row behind that group's embedded chat, if one is running.
fn chatRow(overall: *const Overall, group: []const u8) ?u8 {
    var i: usize = 0;
    while (i < overall.tracked) : (i += 1) {
        const t = overall.slotAt(@intCast(i));
        if (!t.used or t.kind != .chat) continue;
        if (std.mem.eql(u8, t.groupName(), group)) return @intCast(i);
    }
    return null;
}

/// `2026-10-24T08:30:12+08:00`, in the reader's own time, as handoff §5
/// writes every moment of this answer.
///
/// **With the offset, which a bare local time does not carry.** A row's
/// `died at 03:14` read on a machine in another zone, or read back out of a
/// log next week, means nothing without it -- and every other moment in the
/// answer is compared against `now`, which has the same offset.
fn isoOf(arena: Allocator, at_ms: i64, offset_ms: i64) Allocator.Error![]const u8 {
    const secs = @divFloor(at_ms + offset_ms, 1000);
    const ymd = civilFromDays(@divFloor(secs, 86_400));
    const rem: u32 = @intCast(@mod(secs, 86_400));
    const mins: i64 = @divFloor(offset_ms, 60_000);
    // Unsigned, all of it: `{d:0>2}` on a signed integer writes the sign,
    // and a date that reads `+2023-11-15T+7:+12:+20` is not a date.
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(ymd.year)),
        ymd.month,
        ymd.day,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60,
        if (mins < 0) "-" else "+",
        @as(u32, @intCast(@divTrunc(if (mins < 0) -mins else mins, 60))),
        @as(u32, @intCast(@mod(if (mins < 0) -mins else mins, 60))),
    });
}

const Ymd = struct { year: i64, month: u32, day: u32 };

/// Days since 1970 to a date, the way every calendar library does it
/// (Howard Hinnant's `civil_from_days`).
fn civilFromDays(days_in: i64) Ymd {
    const z = days_in + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{ .year = y + (if (m <= 2) @as(i64, 1) else 0), .month = @intCast(m), .day = @intCast(d) };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// One test's scratch memory: the reply is built and parsed into it, and
/// let go at the end. Everything in this file's tests is thrown away whole,
/// which is what an arena is for.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Scratch {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(self: *Scratch) void {
        self.arena.deinit();
    }

    fn alloc(self: *Scratch) Allocator {
        return self.arena.allocator();
    }

    /// The reply, built.
    fn reply(self: *Scratch, overall: *const Overall, in: In) ![]u8 {
        return render(self.alloc(), overall, in);
    }

    /// A reply, parsed. `parseFromSliceLeaky` on `testing.allocator` would
    /// report the whole document as a leak.
    fn parse(self: *Scratch, json: []const u8) !std.json.ObjectMap {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc(), json, .{});
        return v.object;
    }
};

/// A field of an object, or a failure naming it.
fn obj(o: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const v = o.get(key) orelse return error.MissingField;
    return switch (v) {
        .object => |m| m,
        else => error.NotAnObject,
    };
}

fn arr(o: std.json.ObjectMap, key: []const u8) ![]std.json.Value {
    const v = o.get(key) orelse return error.MissingField;
    return switch (v) {
        .array => |a| a.items,
        else => error.NotAnArray,
    };
}

fn num(o: std.json.ObjectMap, key: []const u8) !i64 {
    const v = o.get(key) orelse return error.MissingField;
    return switch (v) {
        .integer => |n| n,
        else => error.NotANumber,
    };
}

fn str(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |t| t,
        else => error.NotAString,
    };
}

fn flag(o: std.json.ObjectMap, key: []const u8) !bool {
    const v = o.get(key) orelse return error.MissingField;
    return switch (v) {
        .bool => |b| b,
        else => error.NotABool,
    };
}

/// A chat called `web-app` in the given pane, holding what the `i`th
/// reading of a 720 MiB-an-hour climb would: 12 MiB a reading, a reading a
/// minute.
fn reading(overall: *Overall, start_ms: i64, now_ms: i64, pane: u64, group: []const u8, i: u64, root: u32) void {
    var p = Overall.PaneReading.named(pane, .chat, group, (200 + i * 12) * mib, 3);
    p.root_pid = root;
    var main = Overall.PaneReading.named(0, .worker, "", (400 + i % 5) * mib, 12);
    main.root_pid = 4242;
    var panes: [1]Overall.PaneReading = .{p};
    overall.sample(.{
        .now_ms = now_ms,
        .start_ms = start_ms,
        .machine = .{
            .mem_total = 32 << 30,
            .mem_used = 20 << 30,
            .swap_used = (4 << 30) + i * mib,
            .swap_total = 24 << 30,
            .disk_free = 40 << 30,
        },
        .main = main,
        .panes = &panes,
    });
}

fn climb(overall: *Overall, n: u64) i64 {
    const start_ms: i64 = 1_700_000_000_000;
    for (0..n) |i| reading(overall, start_ms, start_ms + @as(i64, @intCast(i)) * Overall.hour_ms, 0xab, "web-app", i, 77);
    return start_ms + @as(i64, @intCast(n - 1)) * Overall.hour_ms;
}

test "2149: the answer names every process, with the five things a supervisor reads" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const now = climb(o, 60);

    const facts = [_]GroupFacts{.{ .group = "web-app", .tasks = 128, .tasks_open = 23, .record_bytes = 4_404_019 }};
    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{
        .now_ms = now,
        .offset_ms = 8 * 3600 * 1000,
        .mem_total = 32 << 30,
        .groups = &facts,
    });

    // The reading parses, which is the first thing a reply has to be.
    const root = try scratch.parse(json);
    try testing.expect((try str(root, "at")).len > 0);
    const procs = try arr(try obj(root, "polter"), "processes");
    try testing.expectEqual(@as(usize, 3), procs.len);

    // Each of the five, on every row.
    for (procs) |item| {
        const r = item.object;
        _ = try num(r, "pid");
        _ = try str(r, "kind");
        _ = try num(r, "mem_mib");
        _ = try obj(r, "last_24h");
        _ = try num(try obj(r, "growth"), "slope_mib_per_h");
        // No points unless one process was asked for: absent, or written
        // as a null, both saying the same thing.
        try testing.expect(r.get("points") == null or r.get("points").? == .null);
    }

    // The chat is the one in a group, and it is rising.
    const chat = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "chat")) break item.object;
    } else return error.NoChat;
    try testing.expectEqualStrings("web-app", try str(chat, "group"));
    try testing.expect(try flag(try obj(chat, "growth"), "rising"));
    try testing.expectEqual(@as(i64, 60), try num(try obj(chat, "last_24h"), "samples"));

    // The machine, and the group's own numbers.
    const m = try obj(root, "machine");
    try testing.expectEqual(@as(i64, 32768), try num(m, "mem_total_mib"));
    try testing.expectEqual(@as(i64, 15360), try num(m, "disk_low_line_mib"));
    try testing.expectEqual(false, try flag(m, "disk_low"));
    const g = (try arr(root, "groups"))[0].object;
    const own = try obj(g, "own");
    try testing.expectEqual(@as(i64, 128), try num(own, "tasks"));
    try testing.expectEqual(@as(i64, 23), try num(own, "tasks_open"));
    try testing.expectEqual(@as(i64, 4_404_019), try num(own, "record_bytes"));
}

test "2149: asking for one process gives its points; asking for all gives none" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const now = climb(o, 60);

    var scratch = Scratch.init();
    defer scratch.deinit();
    const one = try scratch.reply(o, .{ .now_ms = now, .offset_ms = 0, .only_pid = 77 });
    const root = try scratch.parse(one);
    const procs = try arr(try obj(root, "polter"), "processes");
    try testing.expectEqual(@as(usize, 1), procs.len);
    const r = procs[0].object;
    try testing.expectEqual(@as(i64, 77), try num(r, "pid"));
    const pts = try arr(r, "points");
    try testing.expectEqual(@as(usize, 60), pts.len);
    // A point is [seconds since Polter started, MiB].
    try testing.expectEqual(@as(usize, 2), pts[0].array.items.len);
    try testing.expect(pts[pts.len - 1].array.items[1].integer > pts[0].array.items[1].integer);
}

test "2149: a group asked for alone leaves the other groups out" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    reading(o, start_ms, start_ms, 0xab, "web-app", 0, 77);
    reading(o, start_ms, start_ms, 0xcd, "billing", 0, 78);
    // Both panes are chats, so both readings made their own row.

    const facts = [_]GroupFacts{ .{ .group = "web-app", .tasks = 5 }, .{ .group = "billing", .tasks = 7 } };
    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{
        .now_ms = start_ms,
        .offset_ms = 0,
        .groups = &facts,
        .only_group = "billing",
    });
    try testing.expect(std.mem.indexOf(u8, json, "web-app") == null);
    const root = try scratch.parse(json);
    const procs = try arr(try obj(root, "polter"), "processes");
    for (procs) |item| try testing.expectEqualStrings("billing", try str(item.object, "group"));
    const gs = try arr(root, "groups");
    try testing.expectEqual(@as(usize, 1), gs.len);
    try testing.expectEqual(@as(i64, 7), try num(try obj(gs[0].object, "own"), "tasks"));
}

test "2149: the machine's swap is judged by the machine's own line, not a process's" {
    // A machine whose swap has been climbing 1.5 GiB an hour: past
    // `swap_rising_mib`, and nowhere near a process's 500 MiB in an hour
    // read wrongly -- it is the same function, weighed differently.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    for (0..60) |i| {
        o.sample(.{
            .now_ms = start_ms + @as(i64, @intCast(i)) * Overall.hour_ms,
            .start_ms = start_ms,
            .machine = .{ .swap_used = (4 << 30) + i * 25 * mib, .swap_total = 24 << 30, .disk_free = 40 << 30 },
            .main = .{ .id = 0, .root_pid = 1, .mem = 400 * mib },
        });
    }
    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{ .now_ms = start_ms + 59 * Overall.hour_ms, .offset_ms = 0 });
    const root = try scratch.parse(json);
    const growth = try obj(try obj(root, "machine"), "swap_growth");
    try testing.expect(try flag(growth, "rising"));
    // 25 MiB a minute is 1500 MiB an hour -- past `swap_rising_mib` -- and
    // the window is the last fifty points, which is the figure shown.
    try testing.expectEqual(@as(i64, 1500), try num(growth, "slope_mib_per_h"));
}

test "2149: a live row and a dead one are told apart, and a row says when it started" {
    // The morning after: a row nothing names any more is still listed, and
    // what it held is what it held when it died. Without `alive` the reader
    // takes a process that stopped at 03:00 for one running now (review #9).
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    var chat = Overall.PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    chat.root_pid = 100;
    chat.start_ms = start_ms - 3600 * 1000;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    const died_at = start_ms + 60_000;
    o.sample(.{ .now_ms = died_at, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib } });

    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{ .now_ms = died_at + 60_000, .offset_ms = 8 * 3600 * 1000 });
    const root = try scratch.parse(json);
    const procs = try arr(try obj(root, "polter"), "processes");

    const dead = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "chat")) break item.object;
    } else return error.NoChat;
    try testing.expectEqual(false, try flag(dead, "alive"));
    // The moment it stopped being named, with the offset this answer's own
    // moments carry.
    const went = try str(dead, "died_at");
    try testing.expect(std.mem.endsWith(u8, went, "+08:00"));
    try testing.expect(went.len == "2026-10-23T16:10:02+08:00".len);
    // And when the process it was started.
    try testing.expect(std.mem.endsWith(u8, try str(dead, "started"), "+08:00"));
    // A chat's row names the terminal it is.
    try testing.expectEqualStrings("0xab", try str(dead, "terminal"));

    // The main process is alive, has no group, is in no terminal, and its
    // `started` is not known here (the reading said nothing).
    const main = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "main")) break item.object;
    } else return error.NoMain;
    try testing.expectEqual(true, try flag(main, "alive"));
    try testing.expect(main.get("group").? == .null);
    try testing.expect(main.get("terminal").? == .null);
    try testing.expect(main.get("started").? == .null);
    try testing.expect(main.get("died_at").? == .null);

    // **The monitor's row carries its sentence**, which says it is inside
    // the main process and already counted there.
    const mon = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "monitor")) break item.object;
    } else return error.NoMonitor;
    try testing.expect((try str(mon, "note")).len > 0);
}

test "2149: what the overall view is drawn from comes out whole" {
    // Review #9: the chart, the segment bar and the cards had nothing to
    // draw from. Each of the fields below is one of §6's marks.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const now = climb(o, 90);

    const facts = [_]GroupFacts{.{
        .group = "web-app",
        .tasks = 128,
        .tasks_open = 23,
        .record_bytes = 4_404_019,
        .supervisor_mib = 1100,
        .workers_mib = 30400,
        .yours_mib = 400,
    }};
    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{
        .now_ms = now,
        .offset_ms = 8 * 3600 * 1000,
        .mem_total = 32 << 30,
        .groups = &facts,
    });
    const root = try scratch.parse(json);

    // The chart: three layers, both spans, with the step the core chose.
    const polter = try obj(root, "polter");
    const series = try obj(polter, "series");
    try testing.expectEqual(@as(i64, 300), try num(series, "hour_step_s"));
    try testing.expectEqual(@as(i64, 1800), try num(series, "week_step_s"));
    for ([_][]const u8{ "hour", "week" }) |span| {
        const ls = try arr(series, span);
        try testing.expectEqual(@as(usize, 3), ls.len);
        const kinds = [_][]const u8{ "main", "chats", "sidecars" };
        for (ls, kinds) |item, want| {
            try testing.expectEqualStrings(want, try str(item.object, "kind"));
            try testing.expect((try arr(item.object, "cells")).len > 0);
        }
    }
    // **The week is the ring that had no way out at all before.** 336 cells
    // half an hour apart is the seven days, and the chats' layer has this
    // group's own chat in it.
    const week = try arr(series, "week");
    try testing.expectEqual(@as(usize, 336), (try arr(week[1].object, "cells")).len);
    const chat_cells = try arr(week[1].object, "cells");
    try testing.expect(chat_cells[chat_cells.len - 1].integer > 0);

    // The two small curves, and the disk one is *free* space -- what the
    // 15 GB line is drawn against.
    const machine = try obj(root, "machine");
    try testing.expect((try arr(machine, "swap_hour")).len > 0);
    const disk = try arr(machine, "disk_hour");
    try testing.expectEqual(@as(usize, 288), disk.len);
    try testing.expect(disk[disk.len - 1].array.items[1].integer > 15 * 1024);

    // The segment bar: four widths that fill the total.
    const g = (try arr(root, "groups"))[0].object;
    const parts = try obj(g, "parts");
    try testing.expectEqual(@as(i64, 1100), try num(parts, "supervisor_mib"));
    try testing.expectEqual(@as(i64, 30400), try num(parts, "workers_mib"));
    try testing.expectEqual(@as(i64, 400), try num(parts, "yours_mib"));
    const own = try obj(g, "own");
    const own_mib = try num(parts, "own_mib");
    try testing.expectEqual(own_mib, try num(own, "chat_mib"));
    const sum = 1100 + 30400 + 400 + own_mib;
    try testing.expectEqual(sum, try num(g, "total_mib"));

    // The "group itself" card: the chat's pid and its own curve.
    try testing.expectEqual(@as(i64, 77), try num(own, "chat_pid"));
    try testing.expect(try flag(try obj(own, "growth"), "rising"));

    // Polter's own CPU, as the number and as the words.
    try testing.expect((try str(polter, "cpu_cores")).len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, try str(polter, "run_started"), 'T') != null);

    // A rising verdict carries the clock time it has been rising since, not
    // only the number of seconds.
    const chat = for (try arr(polter, "processes")) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "chat")) break item.object;
    } else return error.NoChat;
    const since = try str(try obj(chat, "growth"), "since");
    try testing.expect(std.mem.endsWith(u8, since, "+08:00"));
    const first = (try obj(chat, "last_24h")).get("first_mib").?;
    try testing.expect(first.integer > 0);
}

test "2149: the moment is written in the reader's own time, and says which time that is" {
    // 2026-10-24T00:30:12Z, read back with `TZ=UTC date -r 1792801812`.
    const at_ms: i64 = 1_792_801_812_000;
    const utc = try isoOf(testing.allocator, at_ms, 0);
    defer testing.allocator.free(utc);
    try testing.expectEqualStrings("2026-10-24T00:30:12+00:00", utc);
    const local = try isoOf(testing.allocator, at_ms, 8 * 3600 * 1000);
    defer testing.allocator.free(local);
    try testing.expectEqualStrings("2026-10-24T08:30:12+08:00", local);
    // Half-hour zones exist, and a negative one has to keep its sign.
    const india = try isoOf(testing.allocator, at_ms, 5 * 3600 * 1000 + 30 * 60 * 1000);
    defer testing.allocator.free(india);
    try testing.expectEqualStrings("2026-10-24T06:00:12+05:30", india);
    const west = try isoOf(testing.allocator, at_ms, -8 * 3600 * 1000);
    defer testing.allocator.free(west);
    try testing.expectEqualStrings("2026-10-23T16:30:12-08:00", west);
}
