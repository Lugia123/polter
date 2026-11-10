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
    /// **What a terminal is called**, by its pane id: the title the person
    /// gave it, or the one its agent sets (task 3113). Empty when there is
    /// no terminal behind that id, or nothing has named it -- which is a
    /// row the host names by its id alone.
    ///
    /// A callback and not a field on `PaneReading`: the title is the
    /// apprt's, changes while the reading stays the same, and nothing in
    /// the reading needs to hold a copy of it.
    titleOfPane: *const fn (ctx: ?*const anyopaque, pane: u64) []const u8 = noTitle,
    title_ctx: ?*const anyopaque = null,
    /// `{ "group": … }`: only that group's processes. Empty is all.
    only_group: []const u8 = "",
    /// `{ "pid": … }`: only that process, and its 24 hours of points.
    /// Zero is all.
    only_pid: u32 = 0,
};

fn noGroup(_: ?*const anyopaque, _: u64) []const u8 {
    return "";
}

fn noTitle(_: ?*const anyopaque, _: u64) []const u8 {
    return "";
}

/// A terminal's title, or null when nothing named it: an empty title is the
/// caller having none, not a name that happens to be blank.
fn titleOrNull(in: In, pane: u64) ?[]const u8 {
    const title = in.titleOfPane(in.title_ctx, pane);
    return if (title.len > 0) title else null;
}

/// The processes a terminal's row carries, in the reading's order (heaviest
/// first) and copied into `arena`, which is what the reply is written out
/// of.
fn childrenOut(arena: Allocator, children: []const Overall.Child) Allocator.Error![]const Child {
    const out = try arena.alloc(Child, children.len);
    for (children, out) |c, *o| {
        // **The name is copied, not referenced.** `c` is a by-value loop
        // capture: `c.nameOf()` would be a slice into that copy, which is
        // gone by the time the reply is written -- and an invalid string is
        // not a compile error, it is a JSON array of numbers (Zig writes a
        // non-UTF-8 slice as an array), which the host then cannot read.
        o.* = .{ .pid = c.pid, .name = try arena.dupe(u8, c.nameOf()), .mem_mib = c.mem_mib };
    }
    return out;
}

const mib: u64 = 1 << 20;

/// The overall view's stacked layers are read at a cell each: 288
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

/// **The one row the overall view's chart is about** (task 2149, slice 2),
/// as `riseOf` chose it.
///
/// The chart draws one dashed line where the climb began and one sentence
/// beside it, naming who is climbing and by how much -- so a host needs
/// these six and nothing else: it does not work out which row is the one,
/// and it does not work the arithmetic of the sentence out either.
const Rise = struct {
    /// One of `Overall.Category`, the same word the row's own `category` is.
    category: []const u8,
    /// The row's group, null for the main process and the monitor.
    group: ?[]const u8,
    /// **Which process it is**, so that a row can be pointed at. Two
    /// terminals of one group are two rows with one category and one group
    /// between them, and without this a reader who wanted to say which of
    /// them is climbing would have nothing to say it with.
    pid: u32,
    /// When it began climbing, on the same clock as `series.now_s`.
    since_s: u32,
    /// The same moment on the reader's clock, for the sentence.
    since: []const u8,
    /// How much it gained, and the rate it is going at: the row's own two
    /// numbers, so the sentence and the table's orange bar cannot disagree.
    rose_mib: u32,
    slope_mib_per_h: i32,
};

/// **One of the process table's category headings, counted and added up by
/// the core** (task 2149, slice 2, review r2 ①). There is one of them left:
/// the main process (task 3119). A terminal is its own group inside a group
/// of the table (`TableGroup`, task 3113, second round), and the embedded
/// chats stand under the group they belong to rather than under a heading of
/// their own -- one group was otherwise drawn in two places, and a reader
/// had to add the two together to know what it costs.
///
/// The host draws a heading line per group: its name, how many processes are
/// in it, and what they add up to. Both numbers are the core's, because both
/// are the core's rules:
///
///  * **The monitor is in `main` and is not counted there** -- neither in
///    `count` nor in `total_mib`. It is a couple of MiB inside the main
///    process (`Row.inside_main`), and its own memory is already in the main
///    process's row, so adding it in made the main process's group read one
///    process too many and a few MiB too much. The table says so beside the
///    row; the group's own numbers say it by leaving it out.
///  * **How many rows a group has is a count of rows**, which a host is not
///    allowed to do (`tools/control-room-hosts-do-not-decide.py`, rule 2).
///    A host counting them would be the second answer, and the one on
///    screen.
const Section = struct {
    /// One of `Overall.Category`, the group's own name and the order it is
    /// drawn in.
    category: []const u8,
    /// **How many of the rows drawn under this heading count on their
    /// own**: the row marked `inside_main` is still drawn here, as the
    /// "of which" line, and is not counted. Not a number of processes.
    /// That is what the design's heading says -- "内嵌群聊 5 个"
    /// over five chat rows, and the collapsed "还有 N 个" counting the rows
    /// the table is not drawing (`polter-artifacts/2149/v2/src/perf5.py`'s
    /// `table`).
    ///
    /// **Not the processes behind them**: a chat row's and a sidecar row's
    /// own `count` are the terminal's whole process tree (task 3113), so
    /// "5 个" over five chats would have to be thirty.
    count: u32,
    /// What those rows' memory adds up to, MiB; the monitor's own row is
    /// not in it.
    total_mib: u64,
};

/// **One of the process table's group headings, counted and added up here**
/// (task 3119): the table's first layer under the main process. The rows are
/// the terminal and chat rows carrying that group's name (`Row.group`), and
/// both numbers are the core's for the reason `Section`'s are
/// (`tools/control-room-hosts-do-not-decide.py`, rule 2: a host counts no
/// rows and adds nothing up).
///
/// **`group: ""` is the rows in no group, and it is a layer rather than a
/// missing fact** -- a terminal nobody has put in a group would otherwise be
/// invisible. It is drawn last.
///
/// **The order is `In.groups`'** (the control room's own rows), with any
/// group a row names and that list does not carry after those -- so a row is
/// never lost to a stale group list.
const TableGroup = struct {
    /// The group's name; empty for the rows in no group.
    group: []const u8,
    /// How many rows stand under this heading: terminals and chats.
    count: u32,
    /// What those rows' memory adds up to, MiB.
    total_mib: u64,
};

const Polter = struct {
    total_mib: u64,
    /// **The whole tree Polter is responsible for**, MiB: its own process
    /// plus every terminal's tree, which is what the system charges to it
    /// (task 3012; `Overall.treeMib`). **Not `total_mib`**, which is
    /// Polter's own rows. Converted by the same whole-MiB rule as every
    /// other number here.
    ///
    /// **Optional on the host's side too**, so a core that does not send it
    /// leaves a host drawing `total_mib` instead of a tree of zero. Null
    /// before the first reading.
    tree_mib: ?u64,
    /// Tenths of a core, all of Polter's rows together.
    cpu_ds: u32,
    /// The same as "2.6", which is how the card writes it.
    cpu_cores: []const u8,
    monitor_bytes: u64,
    processes: []const Row,
    /// **The process table's category headings**, in the order they are
    /// drawn, each with its own count and total, worked out here (`Section`).
    /// The main process is the one left (task 3119).
    sections: []const Section,
    /// **The process table's group layer under the main process** (task
    /// 3119): one heading per group, in the order the reading knows them,
    /// then the rows in no group. Each carries its own count and total so
    /// that a host draws the first layer without counting anything.
    table_groups: []const TableGroup,
    /// **The one row the overall view's chart is about** (task 2149, slice
    /// 2), as the core chose it; null when nothing is rising.
    ///
    /// The chart draws one rise line and one sentence beside it, naming who
    /// is climbing and by how much. **Which row that is is a rule of the
    /// core's** (`riseOf`), not something a host works out: a host that
    /// picked the largest slope itself would have its own answer for the day
    /// the rule moves, and it would be the one on screen
    /// (`tools/control-room-hosts-do-not-decide.py`).
    rise: ?Rise,
    /// Readings that had no row to go in, so "another N are not tracked" is
    /// answerable rather than silent.
    untracked: u32,
    /// When Polter started, on the reader's clock: `since_s` counts from
    /// here and the chart's x-axis begins here.
    run_started: []const u8,
    /// The stacked layers, a series each, for the 24-hour span and the
    /// week: **two of them** -- the main process and the terminals (task
    /// 3113, second round). This is what the overall view's chart draws,
    /// and neither the week ring nor the category totals had any way out of
    /// the core before it (task 2149's review, #9).
    series: struct {
        hour: []const Layer,
        week: []const Layer,
        /// The step between cells, seconds: the host places a point, it
        /// does not choose the resolution.
        hour_step_s: u32,
        week_step_s: u32,
        /// **The moment the chart's right-hand edge is**, seconds since
        /// Polter started (`Overall.newestAtS`), which is the same clock
        /// `growth.since_s` is on.
        ///
        /// The rise mark is drawn here: the host has the moment a row
        /// started climbing and needs to say where on the chart that is,
        /// and without this it would have to work the window's end out of
        /// the answer's clock (`at` minus `run_started`) -- a second copy
        /// of the core's own arithmetic, and one that is wrong the moment
        /// the two clocks are a minute apart (task 2149, slice 2).
        now_s: u32,
    },
};

const Layer = struct {
    /// One of `Overall.Category`, in the order the stack is drawn.
    ///
    /// **Named `category`, not `kind`**, so that the host may read it: a
    /// host that reads a `kind` is refused outright
    /// (`tools/control-room-hosts-do-not-decide.py`, rule 1), and the
    /// stack's layer names are the one thing about it a host has to have --
    /// they are what the legend's three words are chosen from. The name is
    /// the category the core stacked, so a host draws the core's three in
    /// the core's order and does not work out which is which.
    category: []const u8,
    /// MiB per cell, oldest first.
    cells: []const u32,
};

const Row = struct {
    kind: []const u8,
    /// **Which grouping the table draws this row in**
    /// (`Overall.Category`: `main`, `chats`, `terminals`), worked out here
    /// and not by the host (task 2149, slice 2).
    ///
    /// The host has `kind` beside it and **must not read it**: which kind
    /// belongs to which group is a rule of the core's
    /// (`Overall.categoryOf`), and a host that mapped the four kinds itself
    /// would have its own copy of it -- which is what
    /// `tools/control-room-hosts-do-not-decide.py` refuses. So the group
    /// arrives named, the same way `shown` names a glyph rather than a kind.
    category: []const u8,
    pid: u32,
    /// Null for the main process and the monitor, which are in no group.
    group: ?[]const u8,
    /// How many processes are behind this row. A chat's row and a
    /// terminal's row are a terminal's whole tree (task 3113), so this is
    /// every process in that terminal.
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
    /// When the process behind the row started; null when the platform does
    /// not say.
    started: ?[]const u8,
    /// The terminal this row is, for a sidecar or a chat: its id, written
    /// the way every other terminal id in the control room is
    /// (`0x00000000000000ab`).
    terminal: ?[]const u8,
    /// **What that terminal is called** (task 3113): the title the person
    /// gave it or the one its agent sets, so that a row of the table reads
    /// as the terminal it is rather than as the process kind it has. Null
    /// when nothing has named it, and then the host names the row by its
    /// id alone.
    terminal_title: ?[]const u8,
    /// **The processes in that terminal's tree**, heaviest first (task
    /// 3113, second round): the table draws a terminal as a group, its own
    /// line over these. Empty for a row that is not a terminal, and for
    /// one the core has not read the tree of.
    children: []const Child,
    /// **How many of the tree's processes are not in `children`**: the row
    /// carries a fixed number of them, and a list that stopped at twelve of
    /// thirty-one is a shortened list, which the table says in words rather
    /// than showing as the whole. Zero when every process is listed.
    children_more: u32,
    /// **This row is inside the main process's, already counted there.**
    /// True for the monitor's row alone: it is a couple of MiB living in
    /// `main`, so a reader who adds the rows up must not count it twice.
    ///
    /// **A flag, not the sentence** (slice 2, the supervisor's choice (b)):
    /// the words beside the row are the host's, from its own localised
    /// table. A sentence here would be English on a Chinese page, and
    /// `OverallPage` is not in `GhosttyI18n.zig`'s extractor list -- a
    /// marked word in this file would be in no catalogue at all.
    inside_main: bool = false,
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

/// **One process inside a terminal's tree** (task 3113, second round), as
/// the table's per-terminal group draws it: what it is called, its pid and
/// what it holds. The core chooses which ones and in what order (the
/// heaviest `Overall.max_children`); a host draws the list it was handed.
const Child = struct {
    pid: u32,
    name: []const u8,
    mem_mib: u32,
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

/// The monitor's row is inside the main process's; see `Row.inside_main`.
/// The words a host draws beside it are the host's own, in its own language.
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
            .tree_mib = overall.treeMib(),
            .cpu_ds = cpu_ds,
            .cpu_cores = try tenths(arena, cpu_ds),
            .monitor_bytes = overall.monitorBytes(),
            .processes = rows,
            .sections = try sectionsOf(arena, rows),
            .table_groups = try tableGroupsOf(arena, in, rows),
            .rise = riseOf(rows),
            .untracked = overall.untracked,
            .run_started = try isoOf(arena, overall.run_start_ms, in.offset_ms),
            .series = .{
                .hour = try layers(arena, overall, .hour, hour_cells, hour_cell_s),
                .week = try layers(arena, overall, .week, week_cells, week_cell_s),
                .hour_step_s = hour_cell_s,
                .week_step_s = week_cell_s,
                .now_s = overall.newestAtS(),
            },
        },
        .groups = groups,
    };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

/// **Which row the chart's one rise line is about**, in `arena`.
///
/// The rule, and it is the core's to keep (the supervisor's ruling of
/// 2026-10-25, `rise` (a)): among the rows that are rising, the one that
/// **began rising earliest**; when two began at the same moment, the one
/// that has **gained the most** (`rose_mib`). Null when nothing is rising,
/// which is the ordinary case and not a failure.
///
/// **Why the earliest and not the steepest.** A reader looking at one rise
/// line is asking "what has been climbing longest, so what will be worst by
/// morning"; the steepest row is the answer to a different question, and one
/// that changes every reading.
///
/// **Why this cannot live in a host.** Two hosts that each picked would pick
/// differently on the day the rule moves, and the one on screen would be
/// whichever answered last, with nothing to say which rule it used
/// (`tools/control-room-hosts-do-not-decide.py`, rule 4 refuses the
/// `.max(by:)` this would be written as).
fn riseOf(rows: []const Row) ?Rise {
    var best: ?Row = null;
    for (rows) |row| {
        if (!row.growth.rising) continue;
        // A row read as rising always has the moment it began (`Overall.growth`
        // sets the two together); one that somehow did not is not a row this
        // can place a line for, and is left out rather than drawn at zero.
        if (row.growth.since_s == null or row.growth.since == null) continue;

        if (best) |b| {
            const bs = b.growth.since_s.?;
            const rs = row.growth.since_s.?;
            if (rs > bs) continue;
            if (rs == bs and row.growth.rose_mib <= b.growth.rose_mib) continue;
        }
        best = row;
    }
    const b = best orelse return null;
    return .{
        .category = b.category,
        .group = b.group,
        .pid = b.pid,
        .since_s = b.growth.since_s.?,
        .since = b.growth.since.?,
        .rose_mib = b.growth.rose_mib,
        .slope_mib_per_h = b.growth.slope_mib_per_h,
    };
}

/// **The two layers, in the order the stack is drawn** (task 3113, second
/// round): the main process, and the terminals.
///
/// The chart used to stack three -- the main process, the embedded chats,
/// and what was then the sidecar category. The last two are the same thing
/// to a reader (terminals), and naming the third one after the terminals
/// one by one is not a legend: it is a list. So the two are one band,
/// summed here, and the legend has the two words the table has.
fn layers(arena: Allocator, overall: *const Overall, span: Overall.Span, cells: usize, step_s: u32) Allocator.Error![]const Layer {
    const names = [_][]const u8{ "main", "terminals" };
    const out = try arena.alloc(Layer, names.len);
    for (names, out) |name, *l| {
        const buf = try arena.alloc(u32, cells);
        if (std.mem.eql(u8, name, "main")) {
            overall.categorySeries(.main, span, step_s, buf);
        } else {
            // The two terminal categories, cell by cell: chats and worker
            // terminals are one band.
            overall.categorySeries(.chats, span, step_s, buf);
            const rest = try arena.alloc(u32, cells);
            overall.categorySeries(.terminals, span, step_s, rest);
            for (buf, rest) |*c, v| c.* +|= v;
        }
        l.* = .{ .category = name, .cells = buf };
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
            .terminal => in.groupOfPane(in.ctx, t.pane),
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
            .category = @tagName(Overall.categoryOf(t.kind)),
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
            // Zero for a row whose platform does not say, which is "not
            // known" and not the epoch.
            .started = if (t.start_ms == 0) null else try isoOf(arena, t.start_ms, in.offset_ms),
            .terminal = if (t.kind == .terminal or t.kind == .chat) try hexOf(arena, t.pane) else null,
            // **The terminal's name, for the rows that are terminals**
            // (task 3113): the host writes "title id" instead of one word
            // for every row of the kind. Empty is nothing named it.
            .terminal_title = if (t.kind == .terminal or t.kind == .chat) titleOrNull(in, t.pane) else null,
            // **And the processes inside it**, for the same two kinds.
            .children = try childrenOut(arena, t.childrenOf()),
            // The rest of the tree, counted by the core: the row has room
            // for `Overall.max_children` of them.
            .children_more = if (t.kind == .terminal or t.kind == .chat)
                t.count -| @as(u32, t.children_len)
            else
                0,
            .inside_main = t.kind == .monitor,
            .points = points,
        });
    }
    return out.toOwnedSlice(arena);
}

/// **The process table's category headings, in the order the table draws
/// them** (task 2149, slice 2, review r2 ①): each one's name, how many rows
/// are behind it, and what they add up to -- all of it worked out here
/// (`Section`).
///
/// **One heading is left** (task 3119): the main process. A terminal is its
/// own group under a group of the table (`TableGroup`), and the embedded
/// chats stand under the group they belong to -- a chat is the group's own
/// process (`Row.group`), and drawing it under a heading of its own put one
/// group in two places.
///
/// **Both numbers are the core's to give.** A host that added the rows it
/// was handed up, or that read `processes.count`, would be counting rows
/// (`tools/control-room-hosts-do-not-decide.py`, rule 2) and -- worse --
/// would get the main process's group wrong, because `Overall.categoryOf`
/// puts the monitor there. The monitor is a couple of MiB inside the main
/// process (`Row.inside_main`) and its own memory is already in the main
/// process's row, so it is in neither `count` nor `total_mib`; the row is
/// still drawn under this group's line, which is what the words beside it
/// are for.
///
/// **A group with no rows in this answer is not a line of the table.** An
/// answer about one group (`only_group`) or about one process (`only_pid`)
/// carries only the groups it has rows for, so the table that draws them
/// has no headings over nothing.
fn sectionsOf(arena: Allocator, rows: []const Row) Allocator.Error![]const Section {
    const cats = [_]Overall.Category{.main};
    var out: std.ArrayListUnmanaged(Section) = .empty;
    for (cats) |cat| {
        var any = false;
        var count: u32 = 0;
        var total: u64 = 0;
        for (rows) |row| {
            if (!std.mem.eql(u8, row.category, @tagName(cat))) continue;
            any = true;
            // **The monitor's row is left out of both numbers**, and by its
            // own flag rather than by arithmetic on the category: it is the
            // one row that says of itself that it is already counted in the
            // main process's (`Row.inside_main`). Its line is still drawn
            // under this heading, as the "of which" line -- the heading
            // counts the rows that count on their own, and this one does not.
            if (row.inside_main) continue;
            count += 1;
            total += row.mem_mib;
        }
        if (!any) continue;
        try out.append(arena, .{ .category = @tagName(cat), .count = count, .total_mib = total });
    }
    return out.toOwnedSlice(arena);
}

/// **The table's group layer** (task 3119): one heading per group, in the
/// order the reading knows the groups (`In.groups`, the control room's own
/// rows), then any group a row names and that list does not, then the rows
/// in no group last.
///
/// **Both numbers are worked out here** (`TableGroup`): the rows under a
/// heading are the terminal and chat rows whose `Row.group` is that name,
/// and a host that grouped them itself would be counting rows and adding
/// them up -- the second answer, and the one on screen
/// (`tools/control-room-hosts-do-not-decide.py`, rule 2).
///
/// **A row is never lost to a stale group list.** A group the reading did
/// not list but a row still names gets its own heading after the known ones;
/// rows naming no group (`Row.group` null or empty) get the empty-name
/// heading, which the host draws as "no group".
///
/// **A heading with no rows is not drawn**, as `sectionsOf`' own rule: an
/// answer about one group or one process carries only the groups it has
/// rows for.
fn tableGroupsOf(arena: Allocator, in: In, rows: []const Row) Allocator.Error![]const TableGroup {
    var out: std.ArrayListUnmanaged(TableGroup) = .empty;
    for (in.groups) |g| {
        // A name the list repeats is one heading, not two.
        if (hasTableGroup(out.items, g.group)) continue;
        try appendTableGroup(arena, &out, rows, g.group);
    }
    // A group a row names and the reading did not list, in the order the
    // rows first name it -- kept rather than silently dropped.
    for (rows) |row| {
        const name = rowTableGroup(row) orelse continue;
        if (name.len == 0) continue;
        if (hasTableGroup(out.items, name)) continue;
        try appendTableGroup(arena, &out, rows, name);
    }
    // **The rows in no group, last** -- a terminal nobody has put in a
    // group is still a terminal the person has to be able to see.
    try appendTableGroup(arena, &out, rows, "");
    return out.toOwnedSlice(arena);
}

/// Add one heading's count and total, or nothing when no row stands under it.
fn appendTableGroup(arena: Allocator, out: *std.ArrayListUnmanaged(TableGroup), rows: []const Row, name: []const u8) Allocator.Error!void {
    var count: u32 = 0;
    var total: u64 = 0;
    for (rows) |row| {
        const g = rowTableGroup(row) orelse continue;
        if (!std.mem.eql(u8, g, name)) continue;
        count += 1;
        total += row.mem_mib;
    }
    if (count == 0) return;
    try out.append(arena, .{ .group = try arena.dupe(u8, name), .count = count, .total_mib = total });
}

fn hasTableGroup(groups: []const TableGroup, name: []const u8) bool {
    for (groups) |g| if (std.mem.eql(u8, g.group, name)) return true;
    return false;
}

/// The group a row stands under in the table's group layer: **null for the
/// main process and the monitor**, which stand under the main heading and
/// are in no group; the group's name (empty for none) for a terminal or a
/// chat. Decided by the core's own `category`, not by reading the row's
/// `kind`.
fn rowTableGroup(row: Row) ?[]const u8 {
    if (std.mem.eql(u8, row.category, @tagName(Overall.Category.main))) return null;
    return row.group orelse "";
}

/// A terminal id as the rest of the control room writes one
/// (`ControlRoom.Hex`): sixteen digits, so that the overall view's rows and
/// the control room's own list spell one terminal one way (task 3113).
fn hexOf(arena: Allocator, id: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "0x{x:0>16}", .{id});
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

/// A row with only the things `riseOf` reads filled in, so the picking rule
/// can be asked about a shape no reading produces. `since_s` null is a row
/// that is not rising.
fn riser(category: []const u8, group: ?[]const u8, since_s: ?u32, rose_mib: u32) Row {
    return .{
        .kind = "chat",
        .category = category,
        .pid = 1,
        .group = group,
        .count = 1,
        .mem_mib = 1,
        .cpu_ds = 0,
        .growth = .{
            .rising = since_s != null,
            .slope_mib_per_h = 60,
            .rose_mib = rose_mib,
            .since_s = since_s,
            .since = if (since_s != null) "2026-10-25T00:20:00+08:00" else null,
        },
        .last_24h = .{ .min_mib = 0, .max_mib = 0, .avg_mib = 0, .samples = 0, .first_mib = null, .rising_hours = 0 },
        .alive = true,
        .died_at = null,
        .started = null,
        .terminal = null,
        .terminal_title = null,
        .children = &.{},
        .children_more = 0,
    };
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

test "3012: the answer carries the whole tree as well as Polter's own rows" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    var scratch = Scratch.init();
    defer scratch.deinit();

    // Before a reading there is no tree, and the field says so by being null
    // rather than by a zero a host would draw.
    {
        const json = try scratch.reply(o, .{ .now_ms = 1_700_000_000_000, .offset_ms = 0 });
        const p = try obj(try scratch.parse(json), "polter");
        try testing.expect(p.get("tree_mib") != null and p.get("tree_mib").? == .null);
    }

    // Two readings of `reading()`'s climb, the last of which is main 401 MiB
    // and a chat of 212 MiB. The tree is both; the rows' total is the main
    // process, the chat, the monitor -- and **not** a worker's tree, which is
    // where an agent CLI lives and has no row here at all.
    const now = climb(o, 2);
    const json = try scratch.reply(o, .{ .now_ms = now, .offset_ms = 0 });
    const p = try obj(try scratch.parse(json), "polter");
    try testing.expectEqual(@as(i64, 401 + 212), try num(p, "tree_mib"));
    // The two are different numbers, and that is the point of the field: the
    // rows are a subset of the tree.
    try testing.expect((try num(p, "total_mib")) > (try num(p, "tree_mib")));
}

// **Which grouping of the process table each kind is drawn in** (task 2149,
// slice 2): the answer names it (`Row.category`), so that the two hosts
// draw the core's own groups without either of them owning a copy of the
// rule.
//
// All four kinds in one reading, because the point of the field is that
// **no two of them fall in the same grouping by accident**: `main` and
// `monitor` are `.main` (the monitor is inside the main process), `chat`
// is `.chats` and `terminal` is `.terminals` (task 3113, second round: the
// kind is a terminal, not the sidecar process inside it).
test "2149: the four kinds are named into their groupings" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const chat = Overall.PaneReading.named(0xab, .chat, "web-app", 20 << 30, 3);
    // A terminal with a sidecar behind it: one `polter +mcp`, of its own
    // pid and its own memory.
    const worker = Overall.PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .mem = 3 << 30,
        .procs = 30,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, worker },
    });

    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{ .now_ms = start_ms + 2000, .offset_ms = 8 * 3600 * 1000 });
    const root = try scratch.parse(json);
    const procs = try arr(try obj(root, "polter"), "processes");

    // Every kind the core can write, and the group each belongs in. A
    // fifth kind added to `Overall.Kind` without a place in
    // `Overall.categoryOf` fails to compile there; this list is every kind
    // that reaches a reader.
    const want = [_]struct { kind: []const u8, category: []const u8 }{
        .{ .kind = "main", .category = "main" },
        .{ .kind = "monitor", .category = "main" },
        .{ .kind = "chat", .category = "chats" },
        .{ .kind = "terminal", .category = "terminals" },
    };
    for (want) |w| {
        const row = for (procs) |item| {
            if (std.mem.eql(u8, try str(item.object, "kind"), w.kind)) break item.object;
        } else return error.NoSuchKind;
        try testing.expectEqualStrings(w.category, try str(row, "category"));
    }
    // All four were in the reading, so the loop above was four real rows
    // and not one row matched four times.
    try testing.expectEqual(@as(usize, 4), procs.len);
}

// **The process table's category headings, with their two numbers worked
// out here** (slice 2, review r2 ①; trimmed to one by task 3119). The
// monitor's row is drawn under `main`'s heading and is **not** in either of
// its numbers: it is a couple of MiB inside the main process, whose own row
// already holds them, so counting it in said "2" over one process and added
// its memory a second time.
test "2149: the table's headings leave the monitor's row out of both numbers" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const chat = Overall.PaneReading.named(0xab, .chat, "web-app", 20 << 30, 3);
    const worker = Overall.PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .mem = 3 << 30,
        .procs = 30,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, worker },
    });

    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{ .now_ms = start_ms + 2000, .offset_ms = 0 });
    const root = try scratch.parse(json);
    const polter = try obj(root, "polter");
    const sections = try arr(polter, "sections");

    // **One heading** -- the main process (task 3119). A terminal is its own
    // group inside a group of the table, and a chat stands under the group
    // it belongs to, so there is no `chats` heading any more.
    try testing.expectEqual(@as(usize, 1), sections.len);
    try testing.expectEqualStrings("main", try str(sections[0].object, "category"));

    // The main process's own: **one process and 500 MiB**, though two rows
    // are drawn under this heading. The monitor's row is the second of the
    // two and is not in either number.
    try testing.expectEqual(@as(i64, 1), try num(sections[0].object, "count"));
    try testing.expectEqual(@as(i64, 500), try num(sections[0].object, "total_mib"));

    // And it is left out of the numbers, not out of the table: the row is
    // still there, and still says of itself that it is inside the main
    // process's. **Two rows under this heading and one in its count** is
    // the whole point of the field.
    const procs = try arr(polter, "processes");
    var main_rows: usize = 0;
    var mon: ?std.json.ObjectMap = null;
    for (procs) |item| {
        if (!std.mem.eql(u8, try str(item.object, "category"), "main")) continue;
        main_rows += 1;
        if (std.mem.eql(u8, try str(item.object, "kind"), "monitor")) mon = item.object;
    }
    try testing.expectEqual(@as(usize, 2), main_rows);
    try testing.expect(mon != null);
    try testing.expect(try flag(mon.?, "inside_main"));
    // **The row that would have been double-counted holds something**, so
    // that a total which left it out is a total that left something out: a
    // monitor reading 0 MiB would make the two spellings the same number.
    try testing.expect(try num(mon.?, "mem_mib") > 0);

    // **The chat is under its group now** (task 3119), counted and added up
    // by the core: the web-app group has the one chat row, and the worker
    // names no group, so it is the empty-name heading.
    const groups = try arr(polter, "table_groups");
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("web-app", try str(groups[0].object, "group"));
    try testing.expectEqual(@as(i64, 1), try num(groups[0].object, "count"));
    try testing.expectEqual(@as(i64, 20 * 1024), try num(groups[0].object, "total_mib"));
    try testing.expectEqualStrings("", try str(groups[1].object, "group"));
    try testing.expectEqual(@as(i64, 1), try num(groups[1].object, "count"));

    // **The terminal has no heading and is still a row** (task 3113,
    // second round): its whole tree -- the worker's 3 GiB plus the 200 MiB
    // of its sidecars -- and its own name.
    const term = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "terminal")) break item.object;
    } else return error.NoTerminalRow;
    try testing.expectEqual(@as(i64, (3 << 10) + 200), try num(term, "mem_mib"));
}

// **A terminal's row is the terminal** (task 3113): its whole process tree
// -- the agent CLI, the builds it started, the `polter +mcp` sidecars -- and
// not the sidecars alone, which is what the row used to weigh. That is the
// number the group's own performance page shows for the same terminal, and
// the row is named by the terminal's title and id rather than by one word
// for every row of its kind.
test "3113: a terminal's row is its whole tree, and is named by its title and id" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    // 3000 MiB of tree without its sidecars, 200 MiB of sidecars, thirty
    // processes and two, and the terminal's own process is 4242.
    var worker = Overall.PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .root_pid = 4242,
        .start_ms = start_ms - 60_000,
        .mem = 3000 * mib,
        .procs = 30,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
    };
    // **The processes under the terminal's line** (task 3113, second
    // round), as `OverallRead.build` fills them: heaviest first.
    worker.children[0] = Overall.Child.init(4242, 2600, "claude");
    worker.children[1] = Overall.Child.init(4243, 90, "polter +mcp");
    worker.children_len = 2;
    // The title the person sees on the terminal's tab, by its pane id. A
    // pane nothing named is a row with no title, not one with an empty one.
    const Titles = struct {
        fn of(_: ?*const anyopaque, pane: u64) []const u8 {
            return if (pane == 0xcd) "开发" else "";
        }
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{worker},
    });

    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{
        .now_ms = start_ms + 2000,
        .offset_ms = 0,
        .titleOfPane = Titles.of,
    });
    const root = try scratch.parse(json);
    const procs = try arr(try obj(root, "polter"), "processes");
    const row = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "terminal")) break item.object;
    } else return error.NoTerminalRow;

    // The whole tree, not the sidecars alone.
    try testing.expectEqual(@as(i64, 3000 + 200), try num(row, "mem_mib"));
    try testing.expectEqual(@as(i64, 30 + 2), try num(row, "count"));
    // The terminal's own process is behind the row, not one of the sidecars.
    try testing.expectEqual(@as(i64, 4242), try num(row, "pid"));
    // Named as every other terminal id in the control room is, and with
    // the title the apprt has for it.
    try testing.expectEqualStrings("0x00000000000000cd", try str(row, "terminal"));
    try testing.expectEqualStrings("开发", try str(row, "terminal_title"));
    // **And the processes the table draws under it**, in the order the core
    // chose: the terminal's own line is drawn over these (task 3113,
    // second round).
    const kids = try arr(row, "children");
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(@as(i64, 4242), try num(kids[0].object, "pid"));
    try testing.expectEqualStrings("claude", try str(kids[0].object, "name"));
    try testing.expectEqual(@as(i64, 2600), try num(kids[0].object, "mem_mib"));
    try testing.expectEqual(@as(i64, 4243), try num(kids[1].object, "pid"));
    try testing.expectEqualStrings("polter +mcp", try str(kids[1].object, "name"));
    // **And how many of the tree's processes did not fit**: thirty-two
    // processes, two carried -- the table says "and thirty more" rather
    // than showing two as if they were all.
    try testing.expectEqual(@as(i64, 30), try num(row, "children_more"));
    // A row that is not a terminal has none of the three.
    const main_row = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "main")) break item.object;
    } else return error.NoMainRow;
    try testing.expectEqual(@as(i64, 0), try num(main_row, "children_more"));
}

// **Every worker terminal has a row, with an MCP sidecar in it or not**
// (task 3113, second round) -- the half of the user's complaint the first
// round left open: the terminal running a build and nothing else used to
// have no line at all.
//
// **And the rows add up to the whole tree the first figure draws**, which
// is the equation a reader compares by eye: the rows used to be a subset of
// the tree, and a subset the size of whatever happened to have a sidecar.
test "3113: every terminal is a row, and the rows add up to the whole tree" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const chat = Overall.PaneReading.named(0xab, .chat, "web-app", 2048 * mib, 3);
    const with_sidecar = Overall.PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .root_pid = 99,
        .mem = 3000 * mib,
        .procs = 20,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
    };
    // **The build**: a terminal with no `polter +mcp` in it at all. Before
    // this round it was in no row and in no total.
    const building = Overall.PaneReading{
        .id = 0xce,
        .kind = .worker,
        .root_pid = 98,
        .mem = 1500 * mib,
        .procs = 12,
    };
    // A terminal at its prompt: a shell and nothing else, and still a tree
    // with a process in it.
    const quiet = Overall.PaneReading{
        .id = 0xcf,
        .kind = .worker,
        .root_pid = 97,
        .mem = 40 * mib,
        .procs = 1,
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, with_sidecar, building, quiet },
    });
    // A terminal that goes away: its row is kept for the morning, and it is
    // **drawn and in no tree** -- one of the two things that are in the
    // table and not in the figure.
    o.sample(.{
        .now_ms = start_ms + 60_000,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, with_sidecar, building, quiet, .{
            .id = 0xdf,
            .kind = .worker,
            .root_pid = 96,
            .mem = 700 * mib,
            .procs = 5,
        } },
    });
    // And now it has gone: the reading after it names the four that are
    // left, so its row is dead and its memory is out of the tree.
    o.sample(.{
        .now_ms = start_ms + 120_000,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, with_sidecar, building, quiet },
    });

    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{ .now_ms = start_ms + 180_000, .offset_ms = 0 });
    const root = try scratch.parse(json);
    const polter = try obj(root, "polter");
    const procs = try arr(polter, "processes");

    var terminals: usize = 0;
    var live_mib: u64 = 0;
    var monitor_mib: u64 = 0;
    var dead_mib: u64 = 0;
    var building_mib: ?i64 = null;
    for (procs) |item| {
        const r = item.object;
        const kind = try str(r, "kind");
        const mem: u64 = @intCast(try num(r, "mem_mib"));
        if (try flag(r, "alive")) {
            live_mib += mem;
        } else {
            dead_mib += mem;
        }
        if (std.mem.eql(u8, kind, "monitor")) monitor_mib = mem;
        if (!std.mem.eql(u8, kind, "terminal")) continue;
        terminals += 1;
        if (std.mem.eql(u8, try str(r, "terminal"), "0x00000000000000ce")) {
            building_mib = try num(r, "mem_mib");
        }
    }
    // Four worker terminals -- the one with no sidecar, the quiet one, the
    // one that just went, and the one with the sidecar.
    try testing.expectEqual(@as(usize, 4), terminals);
    try testing.expectEqual(@as(?i64, 1500), building_mib);
    // The one that went is still drawn, with what it held, and is the only
    // row outside the tree.
    try testing.expectEqual(@as(u64, 700), dead_mib);

    // **The equation**: every *live* row is the whole tree. What the table
    // draws and the figure does not are exactly these two things:
    //   * the monitor's own row, whose memory is already inside the main
    //     process's (`inside_main` -- the table says "of which" beside it);
    //   * rows nothing names any more, kept for the morning at what they
    //     held when they went (`alive: false`).
    // What is in neither is what the sampler never attributed to a
    // terminal: a child of the main process that is not a terminal, and the
    // processes it could not read (they are counted in `untracked`).
    //
    // The reader's bound is five percent. On a real machine the two differ
    // by less: each row is floored to whole MiB and the tree is floored
    // once, so the rows can be under by at most a MiB per row -- nowhere
    // near five percent of a tree this size.
    const tree: u64 = @intCast(try num(polter, "tree_mib"));
    const rows = live_mib - monitor_mib;
    try testing.expectEqual(tree, rows);
    const diff = if (rows > tree) rows - tree else tree - rows;
    try testing.expect(diff * 100 <= tree * 5);
}

/// A terminal's group, by pane id, for task 3119's tests: the core does not
/// read this itself -- the app hands it in (`In.groupOfPane`) -- and these
/// are the names the table's first layer is drawn from.
const GroupOf = struct {
    fn of(ctx: ?*const anyopaque, pane: u64) []const u8 {
        _ = ctx;
        return switch (pane) {
            0xab, 0xcd => "web-app",
            0xce => "billing",
            0xdd => "late",
            else => "",
        };
    }
};

// **The table's three layers, counted by the core** (task 3119): the main
// heading, one heading per group in the reading's own order, and the rows
// in no group last.
//
// **The equation is proved across the layers**: the main heading plus every
// group's total is the tree the figure counts. The monitor's row is inside
// the main process and is in neither, and a dead row kept for the morning
// is in the table but not in the tree -- the two things the last round
// named, and this test leaves both out of the reading so that the sum is
// exact rather than close.
test "3119: the table's groups are the core's own headings, and nothing named is lost" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const chat = Overall.PaneReading.named(0xab, .chat, "web-app", 2048 * mib, 3);
    const worker = Overall.PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .root_pid = 99,
        .mem = 3000 * mib,
        .procs = 20,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
    };
    const builder = Overall.PaneReading{
        .id = 0xce,
        .kind = .worker,
        .root_pid = 98,
        .mem = 1500 * mib,
        .procs = 12,
    };
    // A lone prompt: a shell in no group at all.
    const lone = Overall.PaneReading{
        .id = 0xcf,
        .kind = .worker,
        .root_pid = 97,
        .mem = 40 * mib,
        .procs = 1,
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, worker, builder, lone },
    });

    var scratch = Scratch.init();
    defer scratch.deinit();
    // **billing is listed before web-app**, though the rows name it second:
    // the order is the reading's own (`In.groups`), not the rows'.
    const facts = [_]GroupFacts{ .{ .group = "billing" }, .{ .group = "web-app" } };
    const json = try scratch.reply(o, .{
        .now_ms = start_ms + 2000,
        .offset_ms = 0,
        .groups = &facts,
        .groupOfPane = GroupOf.of,
    });
    const root = try scratch.parse(json);
    const polter = try obj(root, "polter");

    // The one category heading left: the main process.
    const sections = try arr(polter, "sections");
    try testing.expectEqual(@as(usize, 1), sections.len);
    try testing.expectEqualStrings("main", try str(sections[0].object, "category"));

    // The three group headings: the two the reading knows, in its order,
    // then the rows in no group -- not dropped, and not before the named
    // groups.
    const groups = try arr(polter, "table_groups");
    const want = [_]struct { group: []const u8, count: i64, total: i64 }{
        .{ .group = "billing", .count = 1, .total = 1500 },
        // The chat and the worker with its sidecar: 2048 + (3000 + 200).
        .{ .group = "web-app", .count = 2, .total = 2048 + 3200 },
        .{ .group = "", .count = 1, .total = 40 },
    };
    try testing.expectEqual(@as(usize, 3), groups.len);
    for (groups, want) |item, w| {
        try testing.expectEqualStrings(w.group, try str(item.object, "group"));
        try testing.expectEqual(w.count, try num(item.object, "count"));
        try testing.expectEqual(w.total, try num(item.object, "total_mib"));
    }

    // **And the layers add up to the whole tree**: the main heading plus
    // every group's total, with the monitor's row in neither.
    const tree: u64 = @intCast(try num(polter, "tree_mib"));
    var sum: u64 = @intCast(try num(sections[0].object, "total_mib"));
    for (groups) |item| sum += @intCast(try num(item.object, "total_mib"));
    try testing.expectEqual(tree, sum);
    try testing.expectEqual(@as(u64, 7288), sum);
}

// **A group a row names and the reading did not list is still a heading**,
// rather than a row that disappears because a list was stale (task 3119).
test "3119: a group the reading did not list is still a heading" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const late = Overall.PaneReading{
        .id = 0xdd,
        .kind = .worker,
        .root_pid = 95,
        .mem = 70 * mib,
        .procs = 2,
    };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{late},
    });
    var scratch = Scratch.init();
    defer scratch.deinit();
    // The reading knows one group and has no row for it; the row names
    // another. The stale one is not drawn over nothing, the row's own is.
    const facts = [_]GroupFacts{.{ .group = "web-app" }};
    const json = try scratch.reply(o, .{
        .now_ms = start_ms + 2000,
        .offset_ms = 0,
        .groups = &facts,
        .groupOfPane = GroupOf.of,
    });
    const root = try scratch.parse(json);
    const groups = try arr(try obj(root, "polter"), "table_groups");
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("late", try str(groups[0].object, "group"));
    try testing.expectEqual(@as(i64, 1), try num(groups[0].object, "count"));
    try testing.expectEqual(@as(i64, 70), try num(groups[0].object, "total_mib"));
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
    // A chat's row names the terminal it is, as the control room writes an
    // id: sixteen digits (task 3113).
    try testing.expectEqualStrings("0x00000000000000ab", try str(dead, "terminal"));

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

    // **The monitor's row says it is inside the main process's**, which is
    // what the words beside it are drawn from; the words themselves are the
    // host's (slice 2's choice (b)).
    const mon = for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "monitor")) break item.object;
    } else return error.NoMonitor;
    try testing.expect(try flag(mon, "inside_main"));
    // And it is the only row that says it: a worker's row is not the main
    // process's, and a reader that counted every row with the flag would
    // drop one it should not.
    for (procs) |item| {
        if (std.mem.eql(u8, try str(item.object, "kind"), "monitor")) continue;
        try testing.expect(!try flag(item.object, "inside_main"));
    }
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

    // **The chart: two layers** (task 3113, second round) -- the main
    // process and the terminals, chats and workers in one band -- for both
    // spans, with the step the core chose.
    const polter = try obj(root, "polter");
    const series = try obj(polter, "series");
    try testing.expectEqual(@as(i64, 300), try num(series, "hour_step_s"));
    try testing.expectEqual(@as(i64, 1800), try num(series, "week_step_s"));
    for ([_][]const u8{ "hour", "week" }) |span| {
        const ls = try arr(series, span);
        try testing.expectEqual(@as(usize, 2), ls.len);
        const names = [_][]const u8{ "main", "terminals" };
        for (ls, names) |item, want| {
            try testing.expectEqualStrings(want, try str(item.object, "category"));
            try testing.expect((try arr(item.object, "cells")).len > 0);
        }
    }
    // **The week is the ring that had no way out at all before.** 336 cells
    // half an hour apart is the seven days, and the terminals' layer has
    // this group's own chat in it.
    const week = try arr(series, "week");
    try testing.expectEqual(@as(usize, 336), (try arr(week[1].object, "cells")).len);
    const term_cells = try arr(week[1].object, "cells");
    try testing.expect(term_cells[term_cells.len - 1].integer > 0);

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

test "2149: the chart's one rise line is the row that began rising earliest" {
    // Three rows climbing, started at 600, 120 and 300 seconds in. The
    // earliest is the chats' one at 120, whatever the others gained.
    const rows = [_]Row{
        riser("main", null, 600, 9_000),
        riser("chats", "web-app", 120, 700),
        riser("terminals", "billing", 300, 1_500),
    };
    const got = (riseOf(&rows)) orelse return error.NoRise;
    try testing.expectEqualStrings("chats", got.category);
    try testing.expectEqualStrings("web-app", got.group.?);
    try testing.expectEqual(@as(u32, 120), got.since_s);
    // The line cannot be placed from a moment alone, so the clock time
    // travels with it.
    try testing.expectEqualStrings("2026-10-25T00:20:00+08:00", got.since);
    try testing.expectEqual(@as(u32, 700), got.rose_mib);
    try testing.expectEqual(@as(i32, 60), got.slope_mib_per_h);

    // **Rows that are not rising are not candidates**, however much they
    // hold: a row sitting at 20 GB has nothing to draw a rise line for.
    const quiet = [_]Row{
        riser("main", null, null, 20_000),
        riser("chats", "web-app", 900, 800),
    };
    try testing.expectEqual(@as(u32, 900), riseOf(&quiet).?.since_s);

    // And with nothing rising there is no line at all, which is what the
    // chart draws most of the time.
    const none = [_]Row{ riser("main", null, null, 20_000), riser("chats", "web-app", null, 300) };
    if (riseOf(&none) != null) return error.ExpectedNoRise;
    const empty: [0]Row = .{};
    if (riseOf(&empty) != null) return error.ExpectedNoRise;
}

test "2149: two rows that began rising at the same moment are settled by how much they gained" {
    // The same second, 400 and 900 MiB: the bigger rise is the one the line
    // is about.
    const tie = [_]Row{
        riser("chats", "web-app", 300, 400),
        riser("terminals", "billing", 300, 900),
    };
    const got = (riseOf(&tie)) orelse return error.NoRise;
    try testing.expectEqualStrings("terminals", got.category);
    try testing.expectEqual(@as(u32, 900), got.rose_mib);

    // ...and the other way round in the reading, which is the half a "take
    // the first one" rule gets wrong. The order of the rows is the reading's
    // and says nothing about which is the bigger rise.
    const again = [_]Row{
        riser("terminals", "billing", 300, 900),
        riser("chats", "web-app", 300, 400),
    };
    const same = (riseOf(&again)) orelse return error.NoRise;
    try testing.expectEqualStrings("terminals", same.category);
    try testing.expectEqual(@as(u32, 900), same.rose_mib);

    // An equal gain as well: whichever is taken, the moment and the amount
    // are the same, so the line and the sentence cannot differ.
    const equal = [_]Row{
        riser("chats", "web-app", 300, 500),
        riser("terminals", "billing", 300, 500),
    };
    const either = (riseOf(&equal)) orelse return error.NoRise;
    try testing.expectEqual(@as(u32, 300), either.since_s);
    try testing.expectEqual(@as(u32, 500), either.rose_mib);

    // A strictly earlier row still wins the tie-break's row: gaining more is
    // only consulted among rows that began together.
    const mixed = [_]Row{
        riser("chats", "web-app", 100, 300),
        riser("terminals", "billing", 100, 800),
        riser("main", null, 50, 200),
    };
    try testing.expectEqualStrings("main", (riseOf(&mixed)).?.category);
}

test "2149: the answer carries the core's own rise, and it is the reading's" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const now = climb(o, 90);

    const facts = [_]GroupFacts{.{ .group = "web-app", .tasks = 4, .tasks_open = 1, .record_bytes = 1024 }};
    var scratch = Scratch.init();
    defer scratch.deinit();
    const json = try scratch.reply(o, .{
        .now_ms = now,
        .offset_ms = 8 * 3600 * 1000,
        .mem_total = 32 << 30,
        .groups = &facts,
    });
    const root = try scratch.parse(json);
    const polter = try obj(root, "polter");

    // The climbing chat is the one row rising in this reading, so the rise
    // is that row's -- and it is the same row the table draws, with the two
    // numbers the sentence uses.
    const rise = try obj(polter, "rise");
    try testing.expectEqualStrings("chats", try str(rise, "category"));
    try testing.expectEqualStrings("web-app", try str(rise, "group"));
    // **Which process it is, not just which group** (slice 2, the reviewer's
    // suggestion): two sidecars of one group are two rows with one group
    // between them, so the group alone does not say which row is climbing.
    // Here the climbing chat is the one `reading` started under pid 77.
    try testing.expectEqual(@as(i64, 77), try num(rise, "pid"));
    const since_s = try num(rise, "since_s");
    try testing.expect(since_s > 0);
    try testing.expect(std.mem.endsWith(u8, try str(rise, "since"), "+08:00"));
    try testing.expect((try num(rise, "rose_mib")) >= Overall.thresholds.rising_mib);

    // The same moment the chart's right-hand edge is on, so the line lands
    // inside the plot and not off it.
    const now_s = try num(try obj(polter, "series"), "now_s");
    try testing.expect(since_s <= now_s);

    // **The row it names is the row the table has.** A rise the table does
    // not contain is a line and a sentence about nothing.
    const procs = try arr(polter, "processes");
    var found = false;
    for (procs) |item| {
        const r = item.object;
        if (!try flag(try obj(r, "growth"), "rising")) continue;
        if (!std.mem.eql(u8, try str(r, "category"), try str(rise, "category"))) continue;
        try testing.expectEqual(try num(try obj(r, "growth"), "since_s"), since_s);
        found = true;
    }
    try testing.expect(found);

    // A reading with nothing climbing has no line rather than a line at zero
    // -- which a host would draw as "rising since Polter started".
    var o2 = try Overall.create(testing.allocator);
    defer o2.destroy();
    var scratch2 = Scratch.init();
    defer scratch2.deinit();
    const start_ms: i64 = 1_700_000_000_000;
    for (0..90) |i| {
        var main = Overall.PaneReading.named(0, .worker, "", 512 * mib, 12);
        main.root_pid = 4242;
        var p = Overall.PaneReading.named(0xab, .chat, "web-app", 512 * mib, 3);
        p.root_pid = 77;
        var panes: [1]Overall.PaneReading = .{p};
        o2.sample(.{
            .now_ms = start_ms + @as(i64, @intCast(i)) * Overall.hour_ms,
            .start_ms = start_ms,
            .machine = .{ .mem_total = 32 << 30, .mem_used = 20 << 30, .swap_used = 4 << 30, .swap_total = 24 << 30, .disk_free = 40 << 30 },
            .main = main,
            .panes = &panes,
        });
    }
    const flat = try scratch2.parse(try scratch2.reply(o2, .{
        .now_ms = start_ms + 89 * Overall.hour_ms,
        .offset_ms = 8 * 3600 * 1000,
        .mem_total = 32 << 30,
        .groups = &facts,
    }));
    const no_rise = (try obj(flat, "polter")).get("rise") orelse return error.MissingField;
    switch (no_rise) {
        .null => {},
        else => return error.ExpectedNull,
    }
}
