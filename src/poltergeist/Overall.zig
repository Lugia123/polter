//! What Polter itself costs, and whether the machine it runs on is running
//! out (task 2149, `polter-artifacts/2149/v2/handoff.md`).
//!
//! The per-terminal readings (`ResourceSampler`, `ledger`, `ResourceRecent`)
//! answer "which terminal is eating the machine". This answers the other two
//! questions a supervisor asks at 3 a.m.: **what is Polter itself holding**
//! -- the main process, every embedded group chat, every MCP sidecar -- and
//! **is the machine running out** of swap or disk.
//!
//! # Nothing here grows
//!
//! This is the hard rule of the task, and the one thing a monitor cannot get
//! wrong: #2147 was a container that only ever grew, and a monitor that leaks
//! while looking for leaks is worse than none.
//!
//!  * Every history is a fixed ring sized at compile time -- `[N]Point`,
//!    never an `ArrayList`.
//!  * The tracked set has a ceiling, `max_tracked`; a process goes into a
//!    slot that already exists, and the least-wanted row is evicted
//!    (handoff §3.2, §3.3).
//!  * The pid lookup is a fixed open-addressed table, not a `HashMap`.
//!  * **The whole structure is one allocation**, taken in `create` and
//!    reported by `monitorBytes`. Nothing is allocated per reading, so
//!    "does the monitor grow" is a question with a one-line answer.
//!
//! The test at the foot of the file samples a hundred thousand times -- two
//! seconds apart, fifty-five hours, with processes being born, dying and
//! changing groups -- and reads the allocator's counter.
//!
//! # Pure where it can be
//!
//! `growth` takes points and answers, with no clock and no process table, so
//! the shapes of "is this rising" are tested here rather than watched for on
//! a machine. Which process is which is `procargs`'s question: the caller
//! reads the table and classifies what it read, and says so in `In`. This
//! file makes no system calls.

const Overall = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What one of Polter's processes is.
pub const Kind = enum { main, chat, sidecar, monitor };

/// One reading of one thing: 12 bytes, so a row's two rings together are
/// 29 376 -- 24 hours at a minute, plus 7 days at ten.
pub const Point = extern struct {
    /// Seconds since Polter started.
    at_s: u32,
    /// MiB.
    mem_mib: u32,
    /// This cell's average CPU, in tenths of a core.
    cpu_ds: u32,
};

/// The last 24 hours, a point a minute.
pub const hour_cap = 1440;
/// The last 7 days, a point every ten minutes.
pub const week_cap = 1008;
pub const hour_ms: i64 = 60_000;
pub const week_ms: i64 = 10 * hour_ms;

/// The three layers the overall view stacks (handoff §6), in the order they
/// are drawn: bottom first. What the reader looks at is the shape of the
/// stack, which no single row has.
///
/// **The monitor is not one of them.** Its row is a couple of MiB inside the
/// main process's, which the main process's own row already counts -- a
/// fourth layer would be the same memory twice. The table says where it
/// lives instead (handoff §6's last row).
pub const Category = enum(u2) { main, chats, sidecars };
pub const categories = 3;

/// Which of the two spans a series is wanted over: the last 24 hours, or the
/// last 7 days.
pub const Span = enum { hour, week };

/// The two small curves under the overall view's chart (handoff §6): the
/// machine's swap, and the startup disk's free space.
pub const MachineSeries = enum { swap, disk };

/// The most things tracked at once: the main process, the embedded group
/// chats, the MCP sidecars, and the monitor's own row.
pub const max_tracked = 64;
/// Slots in the pid lookup: twice `max_tracked`, so it is never more than
/// half full and linear probing stays short.
pub const pid_slots = 128;

/// How long a dead process's row is kept, so the morning after still shows
/// what died overnight (handoff §3.3).
pub const keep_dead_ms: i64 = 24 * 60 * 60 * 1000;

/// The thresholds everything is judged by, in one place rather than spread
/// through the code (handoff §4).
pub const thresholds = struct {
    /// A thing is rising when its window gained at least this.
    pub const rising_mib: u32 = 500;
    /// The window the rise is judged over, seconds.
    pub const window_s: u32 = 3600;
    /// The fewest points in that window worth judging at all. Gaps are
    /// allowed, which is why this is 50 and not 60: a reading missed must
    /// not turn "rising" into "unknown".
    pub const min_points: usize = 50;
    /// The most points a window can hold, and so the size of the buffer
    /// `growthOf` reads one into: a point a minute across `window_s`, plus
    /// the one at its near end.
    ///
    /// **Two more than that**, because a row's first point lands wherever
    /// its first reading did: a row first read at second 59 of a minute and
    /// again at second 0 of the next has two points a second apart, and
    /// with a buffer of exactly `window_s / 60 + 1` one point inside the
    /// window would fall off the back and the hour would be judged as less
    /// than an hour. Two is what that can cost.
    ///
    /// **This number is the whole point of the buffer.** Reading a window
    /// into a buffer shorter than the window is not a smaller window -- it
    /// is a different question, answered wrongly: with 50, a row gaining
    /// 600 MiB an hour was read as steady, because only the last 49 minutes
    /// got in and 49 minutes of 10 MiB a minute is 490.
    pub const window_points: usize = window_s / 60 + 2;
    /// The window is cut into this many segments to see whether the rise is
    /// sustained.
    pub const segments: usize = 6;
    /// ... and this many of them have to rise.
    pub const segments_rising: usize = 5;
    /// No single step may be more than this share of the whole rise: a
    /// process that ate 2 GB at startup and then held still is not leaking.
    pub const max_step_percent: u32 = 40;
    /// The machine's swap rises by this in an hour and it is worth saying.
    pub const swap_rising_mib: u32 = 1024;
    /// Below this much free on the startup disk, macOS starts closing apps.
    /// A line, not a rise (handoff §4).
    pub const disk_low_mib: u64 = 15 * 1024;
};

/// Whether a series is climbing, and by how much: the answer to "is this
/// leaking", as the cards and the process table write it.
pub const Growth = struct {
    rising: bool = false,
    /// The least-squares slope of the window, MiB per hour.
    slope_mib_per_h: i32 = 0,
    /// The second it has been climbing from without pause, on the same clock
    /// as `Point.at_s`; null when it is not rising.
    since_s: ?u32 = null,
    /// How much the window gained, MiB.
    rose_mib: u32 = 0,
};

/// The median memory of up to five points. A median rather than an
/// endpoint so that one spiky reading cannot decide it -- which is what
/// handoff §4 asks for ("the median of the last five points less the median
/// of the first five").
///
/// **Takes points, not a `[5]u32`.** The caller it used to have built the
/// array itself and then passed all five slots whether it had filled them
/// or not; there is no way to write that mistake against a slice.
fn medianMem(points: []const Point) u32 {
    var buf: [5]u32 = undefined;
    const n = @min(points.len, buf.len);
    if (n == 0) return 0;
    for (points[0..n], 0..) |p, k| buf[k] = p.mem_mib;
    std.mem.sort(u32, buf[0..n], {}, std.sort.asc(u32));
    return if (n % 2 == 1) buf[n / 2] else (buf[n / 2 - 1] + buf[n / 2]) / 2;
}

/// Read `points`, oldest first, as rising or not: handoff §4's rules.
///
/// Fewer than `min_points` inside the window and nothing is judged at all: a
/// process just started has no answer, and "not rising" would be a claim the
/// readings do not support.
pub fn growth(points: []const Point) Growth {
    if (points.len == 0) return .{};
    const newest = points[points.len - 1].at_s;

    // The window: everything within `window_s` of the newest point.
    var start: usize = points.len;
    while (start > 0 and newest - points[start - 1].at_s <= thresholds.window_s) start -= 1;
    const win = points[start..];
    if (win.len < thresholds.min_points) return .{};

    // The slope is the window's whether or not it qualifies as rising: a
    // card shows the number either way.
    const slope = slopePerHour(win);

    // Rule 2: it has to have gained this much. The window's first five
    // points and its last five, by the same rule every segment is read by.
    const lo = medianMem(win[0..@min(win.len, 5)]);
    const hi = medianMem(win[win.len - @min(win.len, 5) ..]);
    const rose = hi -| lo;
    if (rose < thresholds.rising_mib) return .{ .slope_mib_per_h = slope, .rose_mib = rose };

    // Rule 4: not in one jump.
    var biggest: u32 = 0;
    for (win[1..], win[0 .. win.len - 1]) |now, was| biggest = @max(biggest, now.mem_mib -| was.mem_mib);
    if (@as(u64, biggest) * 100 > @as(u64, rose) * thresholds.max_step_percent) {
        return .{ .slope_mib_per_h = slope, .rose_mib = rose };
    }

    // Rule 3: sustained. The window is cut into equal segments and a segment
    // rises when its second half's median is above its first half's. The run
    // counted for rule 5 is the one that reaches the present, so a fall with
    // no rise after it ends the run.
    const per = win.len / thresholds.segments;
    if (per < 2) return .{ .slope_mib_per_h = slope, .rose_mib = rose };
    var rising_segments: usize = 0;
    var run_start: ?usize = null;
    var i: usize = 0;
    while (i < thresholds.segments) : (i += 1) {
        const seg = win[i * per ..][0..per];
        const mid = seg.len / 2;
        // **Both halves are slices of the segment, not buffers read whole.**
        // This was two `[5]u32 = undefined` filled by loops over the halves
        // and then handed to `median` entire: with a segment of 8 -- which
        // is what the hour ring's 50 points gave, every time -- the fourth
        // slot of each was never written and the median was taken over a
        // random value, and a segment longer than ten points wrote past the
        // end of the buffer. Neither can happen to a slice.
        //
        // **At most five of each**, which is `median`'s own limit: a
        // segment is judged by where it started and where it ended.
        const head = seg[0..@min(mid, 5)];
        const tail = seg[seg.len - @min(seg.len - mid, 5) ..];
        if (medianMem(tail) > medianMem(head)) {
            rising_segments += 1;
            if (run_start == null) run_start = i;
        } else {
            run_start = null;
        }
    }
    if (rising_segments < thresholds.segments_rising or run_start == null) {
        return .{ .slope_mib_per_h = slope, .rose_mib = rose };
    }

    // Rule 5: how far back the unbroken climb goes.
    return .{
        .rising = true,
        .slope_mib_per_h = slope,
        .since_s = win[run_start.? * per].at_s,
        .rose_mib = rose,
    };
}

/// The least-squares slope of `points` (a minute apart at most), MiB/hour.
fn slopePerHour(points: []const Point) i32 {
    if (points.len < 2) return 0;
    const n: f64 = @floatFromInt(points.len);
    const t0 = points[0].at_s;
    const m0: f64 = @floatFromInt(points[0].mem_mib);
    var st: f64 = 0;
    var sm: f64 = 0;
    var stt: f64 = 0;
    var stm: f64 = 0;
    for (points) |p| {
        const t: f64 = @floatFromInt(p.at_s - t0);
        const m: f64 = @as(f64, @floatFromInt(p.mem_mib)) - m0;
        st += t;
        sm += m;
        stt += t * t;
        stm += t * m;
    }
    const den = n * stt - st * st;
    if (den == 0) return 0;
    const per_h = (n * stm - st * sm) / den * 3600;
    return @intFromFloat(@round(std.math.clamp(per_h, -2.0e9, 2.0e9)));
}

/// A fixed ring over a buffer the owner holds. **The buffer is not inside
/// this**: a `Tracked` is rewritten when a slot is reused, and a slice
/// pointing into itself would dangle.
const Ring = struct {
    len: u16 = 0,
    head: u16 = 0,

    /// One point, dropping the oldest once the buffer is full. This is the
    /// line that makes the histories bounded; the floor test at the foot of
    /// the file replaces it with an append and watches the byte count move.
    fn push(self: *Ring, buf: []Point, p: Point) void {
        const cap: u16 = @intCast(buf.len);
        if (self.len < cap) {
            buf[(@as(usize, self.head) + self.len) % cap] = p;
            self.len += 1;
        } else {
            buf[self.head] = p;
            self.head = (self.head + 1) % cap;
        }
    }

    /// Where the newest point is, so a second reading inside the same cell
    /// can replace it rather than add another: a minute's figure is the end
    /// of the minute, not its first second.
    fn newest(self: *const Ring, buf: []Point) ?*Point {
        if (self.len == 0) return null;
        const cap: usize = buf.len;
        return &buf[(@as(usize, self.head) + self.len - 1) % cap];
    }

    /// The newest `n`, oldest first, into `out`; how many -- fewer when the
    /// ring is shorter than `n`.
    fn tail(self: *const Ring, buf: []const Point, n: usize, out: []Point) usize {
        const have: usize = self.len;
        const want = @min(have, @min(n, out.len));
        const skip = have - want;
        const cap = buf.len;
        var i: usize = 0;
        while (i < want) : (i += 1) out[i] = buf[(@as(usize, self.head) + skip + i) % cap];
        return want;
    }
};

/// One tracked thing: what it is, and where its two rings are.
///
/// Deliberately small -- no buffers of its own. The points live in
/// `Overall.hour` and `Overall.week`, indexed by slot, so reusing a slot
/// costs a `Ring` reset and not a 29 KB copy.
const Tracked = struct {
    used: bool = false,
    kind: Kind = .main,
    /// The process behind the row; 0 for a row that is a tree with no
    /// single process behind it.
    pid: u32 = 0,
    /// When that process started, wall clock milliseconds, so a process
    /// replaced behind the same pid is another process. Zero when the row
    /// is several processes (a sidecar) or the platform does not say.
    start_ms: i64 = 0,
    /// The terminal whose tree this row is: how a chat and a sidecar are
    /// matched from one reading to the next even when their pid moves.
    pane: u64 = 0,
    /// How many processes are behind the row -- a sidecar row may be
    /// several `polter +mcp` processes.
    count: u32 = 1,
    group: [64]u8 = @splat(0),
    group_len: u8 = 0,
    /// The name the *arguments* gave the last time they were read ("the
    /// group this chat was started with"), kept apart from `group`, which
    /// is the name the row answers to.
    ///
    /// **Two names, because the arguments cannot be renamed.** A group
    /// renamed in the control room goes on being spelled the old way in the
    /// arguments of the chat surface already running, so a reading cannot
    /// be allowed to overwrite the row with it -- `renameGroup` would be
    /// undone two seconds later, every two seconds. The arguments decide
    /// only when *they* change: a chat restarted under another `--group=`
    /// is another group, and that is what this field is for.
    arg_group: [64]u8 = @splat(0),
    arg_group_len: u8 = 0,
    /// Whether the reading in progress named it.
    alive: bool = false,
    /// When it was last named, and when it was first not: the 24 hours a
    /// dead row is kept for, and the eviction order.
    seen_ms: i64 = 0,
    died_ms: i64 = 0,
    /// The reading now: memory MiB, and CPU in tenths of a core.
    mem_mib: u32 = 0,
    cpu_ds: u32 = 0,
    /// The last CPU account and moment, so the next reading can be a rate
    /// rather than a total (`touch`). Zero before the first reading, and
    /// after the process behind the row is replaced.
    cpu_last_ns: u64 = 0,
    cpu_last_ms: i64 = 0,
    /// The cell the newest point went in, so readings inside the same minute
    /// or ten minutes do not each add another.
    hour_cell: i64 = -1,
    week_cell: i64 = -1,
    hour_ring: Ring = .{},
    week_ring: Ring = .{},

    pub fn groupName(self: *const Tracked) []const u8 {
        return self.group[0..self.group_len];
    }

    fn setGroup(self: *Tracked, name: []const u8) void {
        const n = @min(name.len, self.group.len);
        @memset(&self.group, 0);
        @memcpy(self.group[0..n], name[0..n]);
        self.group_len = @intCast(n);
    }

    /// The name the arguments gave, as it was last read.
    fn argGroupName(self: *const Tracked) []const u8 {
        return self.arg_group[0..self.arg_group_len];
    }

    fn setArgGroup(self: *Tracked, name: []const u8) void {
        const n = @min(name.len, self.arg_group.len);
        @memset(&self.arg_group, 0);
        @memcpy(self.arg_group[0..n], name[0..n]);
        self.arg_group_len = @intCast(n);
    }
};

/// One entry of the pid lookup: open addressing over a fixed array, so a
/// reading costs no allocation.
const PidEntry = struct { pid: u32 = 0, slot: u8 = 0, used: bool = false };

/// One terminal's reading as the caller worked it out. The caller has
/// already read the process table and classified what it read
/// (`procargs.zig`).
/// What a terminal is, for this feature's purposes: the two things it can
/// be. A worker pane may have sidecars in it, and that is not a third kind
/// -- it is a worker with `sidecar_procs` above zero.
///
/// **Not a `group.len > 0` test.** An embedded chat whose arguments could
/// not be read has an empty group, and reading that as "not a chat" would
/// put the whole chat's memory on a worker's row. Two facts, two fields.
pub const PaneKind = enum { worker, chat };

pub const PaneReading = struct {
    id: u64,
    /// What this terminal is, as its arguments said (`OverallRead`).
    kind: PaneKind = .worker,
    /// The group name: the one the chat was started with, or the group the
    /// terminal a sidecar serves is in. Empty when it is in none.
    ///
    /// **A buffer, not a slice.** A reading is built and thrown away every
    /// two seconds; a slice here would be one allocation per reading, which
    /// is the thing this whole feature must not do.
    group: [64]u8 = @splat(0),
    group_len: u8 = 0,
    /// The tree's root process, when there is one.
    root_pid: u32 = 0,
    /// When that process started, wall clock, milliseconds; zero when the
    /// platform does not say. **This, and not the pid, is what makes a row
    /// a different process**: handoff §4's rule 7 is about the process
    /// being replaced, and a pid is reused while a start moment is not.
    start_ms: i64 = 0,
    /// Bytes, the pane's whole process tree.
    mem: u64 = 0,
    procs: u32 = 0,
    /// Total CPU time of the tree, nanoseconds.
    cpu_ns: u64 = 0,
    /// The `polter +mcp` part of `mem`, `procs` **and `cpu_ns`**, split out
    /// so that the worker's own row does not count it twice (handoff §1).
    ///
    /// **All three are taken apart in the same loop** (`OverallRead.build`),
    /// which is the point: a sidecar's row is those processes alone, so
    /// reading the tree's memory for it *and* the tree's CPU would put a
    /// worker's CPU on its sidecar and leave the worker's own row carrying
    /// CPU that is not its own. Memory was split from the start; CPU was
    /// not, and read as a rate it made a worker look busy for ever (task
    /// 2149's review, r3 ①).
    sidecar_mem: u64 = 0,
    sidecar_procs: u32 = 0,
    /// CPU time of those same processes, nanoseconds.
    sidecar_cpu_ns: u64 = 0,
    /// The sidecar row's process: the **earliest started** of this pane's
    /// `polter +mcp` processes.
    ///
    /// Not the biggest one. With two sidecars of a similar size the biggest
    /// changes from one reading to the next, and the row this names would
    /// then look like a different process every few minutes. The earliest
    /// started changes only when that sidecar goes. **A sidecar row's
    /// history is never cleared for it either way** (`Overall.touch`): the
    /// row is the terminal's sidecars, and which of them the row names is
    /// not the thing being watched.
    sidecar_pid: u32 = 0,

    pub fn groupName(self: *const PaneReading) []const u8 {
        return self.group[0..self.group_len];
    }

    /// A reading with a kind and a group name on it, for the callers that
    /// build one (the app, and the tests below).
    pub fn named(id: u64, kind: PaneKind, group: []const u8, mem: u64, procs: u32) PaneReading {
        var r: PaneReading = .{ .id = id, .kind = kind, .mem = mem, .procs = procs };
        const n = @min(group.len, r.group.len);
        @memcpy(r.group[0..n], group[0..n]);
        r.group_len = @intCast(n);
        return r;
    }
};

/// The machine's own readings. Null where the platform does not answer.
pub const Machine = struct {
    mem_total: ?u64 = null,
    mem_used: ?u64 = null,
    swap_used: ?u64 = null,
    swap_total: ?u64 = null,
    disk_free: ?u64 = null,
};

/// One reading.
pub const In = struct {
    /// Wall clock, milliseconds.
    now_ms: i64,
    /// When Polter started: `Point.at_s` counts from here.
    start_ms: i64,
    machine: Machine = .{},
    /// Polter's own process, as a tree.
    main: PaneReading,
    /// Every terminal, the chat surfaces among them.
    panes: []const PaneReading = &.{},
};

const mib: u64 = 1 << 20;

slots: [max_tracked]Tracked = @splat(.{}),
pids: [pid_slots]PidEntry = @splat(.{}),
/// One past the highest slot ever opened; the ones inside it that are free
/// are found by `used`.
tracked: u8 = 0,

/// The points, by slot. Outside `Tracked` for the reason given there.
hour: [max_tracked][hour_cap]Point = undefined,
week: [max_tracked][week_cap]Point = undefined,

/// Swap and disk: a ring each, on the same cells as a process's.
swap_hour: [hour_cap]Point = undefined,
swap_week: [week_cap]Point = undefined,
disk_hour: [hour_cap]Point = undefined,
disk_week: [week_cap]Point = undefined,
swap_hour_ring: Ring = .{},
swap_week_ring: Ring = .{},
disk_hour_ring: Ring = .{},
disk_week_ring: Ring = .{},
swap_hour_cell: i64 = -1,
swap_week_cell: i64 = -1,
disk_hour_cell: i64 = -1,
disk_week_cell: i64 = -1,

machine: Machine = .{},
/// How many readings were taken.
readings: u64 = 0,
/// When Polter started, wall clock, milliseconds: `Point.at_s` counts from
/// here, so a reply that has to write a clock time can (`OverallPage`'s
/// `since`; handoff §5).
run_start_ms: i64 = 0,
/// Readings of **this** sample that had no row to go in -- see `evict`.
/// The table says "another N are not tracked" rather than dropping them
/// silently, and it says it about the reading in front of the reader:
/// `sample` starts it at zero again. A total that only ever grew would
/// read as tens of thousands by the morning and say nothing about now.
untracked: u32 = 0,

alloc: Allocator,

/// The one allocation. Everything the monitor holds is inside it.
pub fn create(alloc: Allocator) Allocator.Error!*Overall {
    const self = try alloc.create(Overall);
    self.* = .{ .alloc = alloc };
    return self;
}

pub fn destroy(self: *Overall) void {
    const alloc = self.alloc;
    alloc.destroy(self);
}

/// What the monitor itself holds, bytes. One allocation with every buffer
/// inside it, so this is a constant -- which is what makes the monitor's own
/// row on the process table worth reading.
pub fn monitorBytes(self: *const Overall) u64 {
    _ = self;
    return @sizeOf(Overall);
}

/// The main process's pid, or 0 before the first reading.
pub fn mainPid(self: *const Overall) u32 {
    for (self.slots[0..self.tracked]) |t| if (t.used and t.kind == .main) return t.pid;
    return 0;
}

/// How many rows are in use, dead ones among them.
pub fn trackedCount(self: *const Overall) usize {
    var n: usize = 0;
    for (self.slots[0..self.tracked]) |t| {
        if (t.used) n += 1;
    }
    return n;
}

/// The first row of that kind, if there is one.
pub fn slotOfKind(self: *const Overall, kind: Kind) ?u8 {
    for (self.slots[0..self.tracked], 0..) |t, i| {
        if (t.used and t.kind == kind) return @intCast(i);
    }
    return null;
}

/// That row of that kind among several -- chat 0, chat 1...
pub fn slotOfKindAt(self: *const Overall, kind: Kind, n: usize) ?u8 {
    var seen: usize = 0;
    for (self.slots[0..self.tracked], 0..) |t, i| {
        if (!t.used or t.kind != kind) continue;
        if (seen == n) return @intCast(i);
        seen += 1;
    }
    return null;
}

pub fn slotAt(self: *const Overall, i: u8) *const Tracked {
    return &self.slots[i];
}

pub fn groupOf(self: *const Overall, i: u8) []const u8 {
    return self.slots[i].groupName();
}

/// This row's last hour, as `growth` reads it.
///
/// **The whole window, not `min_points` of it.** `growth` drops the points
/// outside its window itself; handing it a shorter buffer hands it a
/// shorter hour, and the verdict is then about a window nobody asked for.
pub fn growthOf(self: *const Overall, i: u8) Growth {
    var buf: [thresholds.window_points]Point = undefined;
    const n = self.slots[i].hour_ring.tail(&self.hour[i], buf.len, &buf);
    return growth(buf[0..n]);
}

/// What a row's last 24 hours came to, for the summary on its card
/// (handoff §5's `last_24h`): the shape `ResourcePage`'s cards have.
pub const Summary = struct {
    min_mib: u32 = 0,
    max_mib: u32 = 0,
    avg_mib: u32 = 0,
    /// How many minute points the window held -- well under 1440 for a
    /// thing that started this afternoon, and that is worth saying.
    samples: u32 = 0,
};

pub fn summarize(self: *const Overall, i: u8) Summary {
    const ring = &self.slots[i].hour_ring;
    if (ring.len == 0) return .{};
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var sum: u64 = 0;
    var k: usize = 0;
    while (k < ring.len) : (k += 1) {
        const p = self.hour[i][(@as(usize, ring.head) + k) % hour_cap];
        lo = @min(lo, p.mem_mib);
        hi = @max(hi, p.mem_mib);
        sum += p.mem_mib;
    }
    return .{
        .min_mib = lo,
        .max_mib = hi,
        .avg_mib = @intCast(sum / ring.len),
        .samples = ring.len,
    };
}

/// Every point of a row's 24 hours, oldest first, into `out`; how many.
/// For `{ "pid": … }`, which is the only caller that wants them.
pub fn hourPoints(self: *const Overall, i: u8, out: []Point) usize {
    return self.slots[i].hour_ring.tail(&self.hour[i], out.len, out);
}

/// The same for the seven days: the ring that had no way out of this file
/// until the overall view needed a week to draw (task 2149's review, #9).
pub fn weekPoints(self: *const Overall, i: u8, out: []Point) usize {
    return self.slots[i].week_ring.tail(&self.week[i], out.len, out);
}

/// The machine's own history: swap and disk, hour or week, oldest first.
pub fn machinePoints(self: *const Overall, which: MachineSeries, span: Span, out: []Point) usize {
    return switch (which) {
        .swap => switch (span) {
            .hour => self.swap_hour_ring.tail(&self.swap_hour, out.len, out),
            .week => self.swap_week_ring.tail(&self.swap_week, out.len, out),
        },
        .disk => switch (span) {
            .hour => self.disk_hour_ring.tail(&self.disk_hour, out.len, out),
            .week => self.disk_week_ring.tail(&self.disk_week, out.len, out),
        },
    };
}

/// How much a row held when its 24 hours began -- the figure the card's
/// "16 hours ago it was 0.6 GB" is written from (handoff §5's
/// `last_24h.first_mib`). Null before anything was read.
pub fn firstMib(self: *const Overall, i: u8) ?u32 {
    const ring = &self.slots[i].hour_ring;
    if (ring.len == 0) return null;
    return self.hour[i][ring.head].mem_mib;
}

/// How many of the last 24 hours this row was rising in, by `growth`'s own
/// rules applied to each hour (`last_24h.rising_hours`).
///
/// **An hour that was not read enough to judge is not counted as flat**: a
/// row that started ten minutes ago has 0 rising hours and 0 judged ones,
/// and the two are not the same claim -- which is why the count is only
/// ever read next to `samples`.
pub fn risingHours(self: *const Overall, i: u8) u32 {
    var buf: [hour_cap]Point = undefined;
    const n = self.hourPoints(i, &buf);
    if (n == 0) return 0;
    const newest = buf[n - 1].at_s;
    var hours: u32 = 0;
    var k: u32 = 0;
    while (k < 24) : (k += 1) {
        const hi = newest -| k * 3600;
        const lo = hi -| 3600;
        // The hour's points: this hour's own, plus the one that opened it.
        var start: usize = n;
        var count: usize = 0;
        for (buf[0..n], 0..) |p, j| {
            if (p.at_s > hi) break;
            if (p.at_s >= lo) {
                if (start == n) start = j;
                count += 1;
            }
        }
        if (count < thresholds.min_points) continue;
        if (growth(buf[start .. start + count]).rising) hours += 1;
    }
    return hours;
}

/// The machine's swap, as `growth` reads it. Rising here means the machine
/// is running out; the caller weighs it by `thresholds.swap_rising_mib`,
/// which is not `rising_mib`. The whole window, for `growthOf`'s reason.
pub fn swapGrowth(self: *const Overall) Growth {
    var buf: [thresholds.window_points]Point = undefined;
    const n = self.swap_hour_ring.tail(&self.swap_hour, buf.len, &buf);
    return growth(buf[0..n]);
}

/// Total MiB held by Polter's own rows: the main process, the chats, the
/// sidecars and the monitor. The monitor's is a couple of MiB inside the
/// main process's and is counted here like any other row -- the table says
/// where it lives, rather than subtracting it and leaving a hole.
pub fn totalMib(self: *const Overall) u64 {
    var total: u64 = 0;
    for (self.slots[0..self.tracked]) |t| {
        if (!t.used) continue;
        total += t.mem_mib;
    }
    return total;
}

/// Whether the disk is below the line macOS starts closing apps at.
pub fn diskLow(self: *const Overall) bool {
    const free = self.machine.disk_free orelse return false;
    return free / mib < thresholds.disk_low_mib;
}

/// A group renamed (handoff §7.4, `group_stores.Table.overall_rows`): every
/// row that was that group's is the new group's from here.
///
/// **Needed even though a row's name is read every time.** What a chat row
/// is named comes from the arguments of the process the control room
/// started, and those go on saying the name it was started with until the
/// chat is started again -- so a renamed group's chat row would carry the
/// old name for as long as that surface lives, and
/// `groups[].own.chat_mib` would find no chat of the new name and read 0.
///
/// **The history comes with the row.** It is the same group: the same
/// terminal, the same process, the same leak.
pub fn renameGroup(self: *Overall, from: []const u8, to: []const u8) void {
    for (self.slots[0..self.tracked]) |*t| {
        if (!t.used) continue;
        if (!std.mem.eql(u8, t.groupName(), from)) continue;
        t.setGroup(to);
    }
}

/// A group deleted (`group_stores.Table.overall_rows`): its rows go now.
///
/// Not left to age out. A group nobody has any more would otherwise sit in
/// the process table for the rest of the 24 hours a dead row is kept, read
/// as a group that still exists -- and `resource_overview` refuses a group
/// nobody has, so the two would disagree about the same name.
pub fn forgetGroup(self: *Overall, name: []const u8) void {
    for (self.slots[0..self.tracked], 0..) |*t, i| {
        if (!t.used) continue;
        if (!std.mem.eql(u8, t.groupName(), name)) continue;
        self.unindex(@intCast(i));
        t.* = .{};
    }
}

/// One reading: fold it in, open rows for what is new, retire what is gone.
pub fn sample(self: *Overall, in: In) void {
    self.readings += 1;
    self.machine = in.machine;
    // When Polter started, kept, because a reply that has to write a clock
    // time for a row's `since` has nothing else to count from (handoff §5).
    self.run_start_ms = in.start_ms;
    // **This reading's dropped rows, not every row ever dropped.** The
    // table's last line says "another N are not tracked" -- a figure about
    // the picture in front of the reader. Let to run, it counted the
    // history of the whole night and would read as tens of thousands.
    self.untracked = 0;
    const at_s: u32 = @intCast(@max(0, @divFloor(in.now_ms - in.start_ms, 1000)));

    for (self.slots[0..self.tracked]) |*t| t.alive = false;

    // The main process first, so slot 0 is always it.
    self.touch(.main, in.main, in, at_s, 0);

    for (in.panes) |p| switch (p.kind) {
        // An embedded chat: the pane's whole tree is the group's own.
        .chat => self.touch(.chat, p, in, at_s, p.id),
        // An ordinary terminal. Its sidecars are split out of its row so
        // they are not counted twice (handoff §1); one with none is not a
        // row here at all -- the terminal's own card is the pane feature's.
        .worker => if (p.sidecar_procs > 0) self.touch(.sidecar, p, in, at_s, p.id),
    };

    // The monitor's own row: what this structure holds, which does not move.
    self.touchMonitor(in, at_s);

    self.retire(in.now_ms);
    self.pushMachine(in.now_ms, at_s);
}

/// Fold one thing's reading into its row, opening one if it is new.
fn touch(self: *Overall, kind: Kind, r: PaneReading, in: In, at_s: u32, pane: u64) void {
    // A sidecar row is the `polter +mcp` processes alone; the chat's row is
    // the whole pane. Reading the tree's memory **or its CPU** for a
    // sidecar would put a worker's cost on its sidecar's row and count it
    // twice over, which is why a worker's reading loses both before it
    // arrives (`OverallRead.build`).
    const mine = if (kind == .sidecar) .{ r.sidecar_mem, @max(1, r.sidecar_procs) } else .{ r.mem, r.procs };
    const cpu_ns: u64 = if (kind == .sidecar) r.sidecar_cpu_ns else r.cpu_ns;
    const pid: u32 = if (kind == .sidecar) r.sidecar_pid else r.root_pid;
    // The moment the process behind the row started -- **zero for a row
    // with several processes behind it**, a sidecar row being the one, so
    // that its own pid moving between two similar sidecars does not read
    // as "another process". It is a fact about one process, and a row that
    // is not one process does not have it.
    const started: i64 = if (kind == .sidecar) 0 else r.start_ms;
    const slot = self.slotFor(kind, r, in, pane, pid) orelse return;
    const t = &self.slots[slot];
    t.alive = true;
    t.seen_ms = in.now_ms;
    t.died_ms = 0;
    t.mem_mib = @intCast(@min(mine[0] / mib, std.math.maxInt(u32)));
    t.count = mine[1];

    // Rule 7 of handoff §4: a process replaced is another process, so its
    // history starts again. The row is the same -- the same terminal, the
    // same group -- but the curve is the new process's.
    //
    // **A start moment, and only for a row that is one process.** A pid is
    // reused by the system, and moves between two processes of the same
    // shape (the two sidecars of a pane); a start moment does not. And a
    // sidecar row is several processes, which is why `started` is zero for
    // it (`touch`'s caller above): its history is the terminal's sidecars
    // together, and clearing it because the row happens to name another
    // one would leave a row being watched for a leak with no curve at all.
    //
    // **Before the CPU account below, not after.** This clears the old
    // process's `cpu_last_*`, and that has to happen first: clearing them
    // afterwards would throw away the baseline the same reading had just
    // laid down, and the reading *after* the replacement -- the first that
    // could measure anything -- would report nothing as well.
    if (started != 0 and started != t.start_ms) {
        t.start_ms = started;
        t.hour_ring = .{};
        t.week_ring = .{};
        t.hour_cell = -1;
        t.week_cell = -1;
        // Another process's CPU account: the difference from the old one's
        // total is not a rate, it is noise.
        t.cpu_last_ns = 0;
        t.cpu_last_ms = 0;
    }
    if (started == 0) t.start_ms = 0;

    // **A rate, not the process's lifetime total.** The accumulator is CPU
    // time since the process started -- an hour-old main process reads as
    // 18020 tenths of a core this way, and every row's CPU only ever
    // climbs. What a point means is "the average over this interval", so
    // the interval's difference is what is kept (`Point.cpu_ds`).
    //
    // Zero when there is nothing to measure from: the first reading of a
    // row, and the first after the process behind it is replaced (the
    // account starting again would read as a huge negative). Zero says
    // "not measured", which is what it is -- not "no CPU".
    //
    // **A backwards interval is guarded, not wrapped.** A `u64` subtraction
    // that went the wrong way would land near 2^64, and the result would be
    // a colossal rate -- the one shape of a wrong answer that reads as a
    // real finding. The comparison is `>=`, which also covers the sidecar
    // row: its reading is a sum over whichever `polter +mcp` processes are
    // alive, so one of them going makes the sum fall.
    if (t.cpu_last_ms != 0 and in.now_ms > t.cpu_last_ms and cpu_ns >= t.cpu_last_ns) {
        const dt_ms: u64 = @intCast(in.now_ms - t.cpu_last_ms);
        const used: u128 = cpu_ns - t.cpu_last_ns;
        // Ticks of CPU per tick of wall time, times ten: tenths of a core.
        // Exact, not float: a rate is a whole number of tenths anyway.
        t.cpu_ds = @intCast(@min(used * 10 / (@as(u128, dt_ms) * std.time.ns_per_ms), std.math.maxInt(u32)));
    } else {
        t.cpu_ds = 0;
    }
    t.cpu_last_ns = cpu_ns;
    t.cpu_last_ms = in.now_ms;

    // **The name the row answers to, from the reading -- unless the
    // arguments have not changed.**
    //
    // The arguments of a running chat surface cannot be renamed: a group
    // renamed in the control room is still spelled the old way there for as
    // long as that surface lives. Copying them in every reading would undo
    // `renameGroup` two seconds later, every two seconds, and
    // `groups[].own.chat_mib` would go on reading 0 -- which is the defect
    // this was meant to fix. So the arguments speak only when *they* moved
    // (a chat restarted under another `--group=` is another group), and
    // `renameGroup` holds otherwise.
    const from_reading = r.groupName();
    if (!std.mem.eql(u8, from_reading, t.argGroupName())) {
        t.setArgGroup(from_reading);
        t.setGroup(from_reading);
    }

    // The pid the row looks up by, always current: `rowOfPid` is asked
    // which row a process is, and a row that goes on answering to a pid it
    // no longer has would put the wrong row's card on a process.
    if (t.pid != pid) {
        self.unindex(slot);
        t.pid = pid;
        self.indexPid(slot);
    }

    self.put(t, slot, .{ .at_s = at_s, .mem_mib = t.mem_mib, .cpu_ds = t.cpu_ds }, in.now_ms);
}

/// The monitor's own row: it holds `monitorBytes`, and it lives inside the
/// main process, which the row says rather than subtracts.
fn touchMonitor(self: *Overall, in: In, at_s: u32) void {
    const mine: PaneReading = .{ .id = @intFromPtr(self), .mem = self.monitorBytes(), .procs = 1 };
    const slot = self.slotFor(.monitor, mine, in, 0, 0) orelse return;
    const t = &self.slots[slot];
    t.alive = true;
    t.seen_ms = in.now_ms;
    t.died_ms = 0;
    t.mem_mib = @intCast(@max(1, self.monitorBytes() / mib));
    t.cpu_ds = 0;
    t.count = 1;
    // The monitor's row keeps the same rings as everything else, so a person
    // watching it can see the flat line it is meant to be.
    self.put(t, slot, .{ .at_s = at_s, .mem_mib = t.mem_mib, .cpu_ds = 0 }, in.now_ms);
}

/// One point into a row's two rings, on the cell the clock is in.
fn put(self: *Overall, t: *Tracked, slot: u8, point: Point, now_ms: i64) void {
    const hour_cell = @divFloor(now_ms, hour_ms);
    if (hour_cell != t.hour_cell) {
        t.hour_cell = hour_cell;
        t.hour_ring.push(&self.hour[slot], point);
    } else if (t.hour_ring.newest(&self.hour[slot])) |newest| newest.* = point;
    const week_cell = @divFloor(now_ms, week_ms);
    if (week_cell != t.week_cell) {
        t.week_cell = week_cell;
        t.week_ring.push(&self.week[slot], point);
    } else if (t.week_ring.newest(&self.week[slot])) |newest| newest.* = point;
}

/// The row for this thing: the one it already has, a free one, or an
/// eviction. Null when nothing can be evicted and the reading is dropped.
fn slotFor(self: *Overall, kind: Kind, r: PaneReading, in: In, pane: u64, pid: u32) ?u8 {
    if (self.lookup(kind, pane)) |s| return s;
    for (self.slots[0..self.tracked], 0..) |t, i| {
        if (!t.used) return self.open(@intCast(i), kind, r, in, pane, pid);
    }
    if (self.tracked < max_tracked) {
        const i = self.tracked;
        self.tracked += 1;
        return self.open(i, kind, r, in, pane, pid);
    }
    return self.evict(kind, r, in, pane, pid);
}

/// The row that is already this thing. A chat and a sidecar are matched by
/// their pane -- the process behind one may be replaced while the terminal
/// stays -- and the main process and the monitor are single, so by kind.
fn lookup(self: *Overall, kind: Kind, pane: u64) ?u8 {
    switch (kind) {
        .main => return self.slotOfKind(.main),
        .monitor => return self.slotOfKind(.monitor),
        .chat, .sidecar => {},
    }
    for (self.slots[0..self.tracked], 0..) |t, i| {
        if (!t.used or t.kind != kind) continue;
        if (t.pane == pane) return @intCast(i);
    }
    return null;
}

fn open(self: *Overall, i: u8, kind: Kind, r: PaneReading, in: In, pane: u64, pid: u32) u8 {
    self.unindex(i);
    const t = &self.slots[i];
    t.* = .{
        .used = true,
        .kind = kind,
        .pid = pid,
        // The process behind the row, as the reading said -- not the moment
        // this row opened, which is a different fact and a useless one
        // (see `touch`).
        .start_ms = if (kind == .sidecar) 0 else r.start_ms,
        .pane = pane,
        .count = 1,
        .alive = true,
        .seen_ms = in.now_ms,
    };
    t.setGroup(r.groupName());
    t.setArgGroup(r.groupName());
    self.indexPid(i);
    return i;
}

/// The least-wanted row when all of them are taken (handoff §3.3): the one
/// dead longest; with all of them alive, the smallest sidecar. The main
/// process, a chat or the monitor is never thrown away for a sidecar, and
/// with nothing evictable the reading is dropped and counted.
fn evict(self: *Overall, kind: Kind, r: PaneReading, in: In, pane: u64, pid: u32) ?u8 {
    var chosen: ?usize = null;
    var any_dead = false;
    for (self.slots[0..self.tracked], 0..) |t, i| {
        if (!t.used or t.alive) continue;
        any_dead = true;
        if (chosen) |c| {
            if (t.died_ms >= self.slots[c].died_ms) continue;
        }
        chosen = i;
    }
    if (!any_dead and kind == .sidecar) {
        for (self.slots[0..self.tracked], 0..) |t, i| {
            if (t.kind != .sidecar) continue;
            if (chosen) |c| {
                if (t.mem_mib >= self.slots[c].mem_mib) continue;
            }
            chosen = i;
        }
    }
    const i = chosen orelse {
        self.untracked += 1;
        return null;
    };
    return self.open(@intCast(i), kind, r, in, pane, pid);
}

/// Drop the rows nothing has named for `keep_dead_ms`, and stamp the rest
/// dead so the eviction order is the order they died in.
fn retire(self: *Overall, now_ms: i64) void {
    var i: usize = 0;
    while (i < self.tracked) : (i += 1) {
        const t = &self.slots[i];
        if (!t.used or t.alive) continue;
        if (t.died_ms == 0) t.died_ms = now_ms;
        if (now_ms - t.died_ms <= keep_dead_ms) continue;
        self.unindex(@intCast(i));
        t.* = .{};
    }
}

fn indexPid(self: *Overall, i: u8) void {
    const pid = self.slots[i].pid;
    if (pid == 0) return;
    var k: usize = pid % pid_slots;
    var probes: usize = 0;
    while (probes < pid_slots) : (probes += 1) {
        const e = &self.pids[k];
        if (!e.used) {
            e.* = .{ .pid = pid, .slot = i, .used = true };
            return;
        }
        if (e.pid == pid) {
            e.slot = i;
            return;
        }
        k = (k + 1) % pid_slots;
    }
}

fn unindex(self: *Overall, i: u8) void {
    const pid = self.slots[i].pid;
    if (pid == 0) return;
    var k: usize = pid % pid_slots;
    var probes: usize = 0;
    while (probes < pid_slots) : (probes += 1) {
        const e = &self.pids[k];
        if (!e.used) return;
        if (e.pid == pid and e.slot == i) {
            e.used = false;
            return;
        }
        k = (k + 1) % pid_slots;
    }
}

/// Which row a pid is, if any: what makes "the process behind this row is not
/// the one that was there" answerable without a map.
pub fn rowOfPid(self: *const Overall, pid: u32) ?u8 {
    if (pid == 0) return null;
    var k: usize = pid % pid_slots;
    var probes: usize = 0;
    while (probes < pid_slots) : (probes += 1) {
        const e = self.pids[k];
        if (!e.used) return null;
        if (e.pid == pid) return e.slot;
        k = (k + 1) % pid_slots;
    }
    return null;
}

/// What a row is, in the three layers the overall view stacks.
pub fn categoryOf(kind: Kind) Category {
    return switch (kind) {
        .main, .monitor => .main,
        .chat => .chats,
        .sidecar => .sidecars,
    };
}

/// One layer of the stack at each of `cells.len` cells `step_s` apart, MiB,
/// oldest cell first: the category's rows added up on one time base.
///
/// **Every row of the layer is resampled against its own newest point and
/// then added**, rather than each row placed against one global clock: two
/// rows read a minute apart are both "now" at the right-hand edge, which is
/// what a stacked chart means by the present.
pub fn categorySeries(self: *const Overall, cat: Category, span: Span, step_s: u32, cells: []u32) void {
    @memset(cells, 0);
    if (cells.len == 0) return;
    var buf: [hour_cap]Point = undefined;
    var row_cells: [week_cap]u32 = undefined;
    const out_cells = @min(cells.len, row_cells.len);
    var i: usize = 0;
    while (i < self.tracked) : (i += 1) {
        const t = &self.slots[i];
        if (!t.used or categoryOf(t.kind) != cat) continue;
        const n = switch (span) {
            .hour => self.hourPoints(@intCast(i), &buf),
            .week => self.weekPoints(@intCast(i), &buf),
        };
        if (n == 0) continue;
        resample(buf[0..n], step_s, row_cells[0..out_cells]);
        for (cells[0..out_cells], row_cells[0..out_cells]) |*c, v| c.* +|= v;
    }
}

/// The same for one of the machine's own curves, from its own ring.
pub fn machineSeries(self: *const Overall, which: MachineSeries, span: Span, step_s: u32, cells: []u32) void {
    @memset(cells, 0);
    if (cells.len == 0) return;
    var buf: [hour_cap]Point = undefined;
    const n = self.machinePoints(which, span, &buf);
    resample(buf[0..n], step_s, cells);
}

/// The newest moment anything has a point for, or 0 before the first
/// reading: the right-hand edge of every chart in the reply.
pub fn newestAtS(self: *const Overall) u32 {
    var newest: u32 = 0;
    var buf: [hour_cap]Point = undefined;
    var i: usize = 0;
    while (i < self.tracked) : (i += 1) {
        if (!self.slots[i].used) continue;
        const n = self.hourPoints(@intCast(i), &buf);
        if (n > 0) newest = @max(newest, buf[n - 1].at_s);
    }
    const swap_n = self.swap_hour_ring.tail(&self.swap_hour, buf.len, &buf);
    if (swap_n > 0) newest = @max(newest, buf[swap_n - 1].at_s);
    const disk_n = self.disk_hour_ring.tail(&self.disk_hour, buf.len, &buf);
    if (disk_n > 0) newest = @max(newest, buf[disk_n - 1].at_s);
    return newest;
}

/// One layer of the stack, resampled to `cells` cells `step_s` apart, newest
/// cell last -- the same shape `categorySeries` produces, from points the
/// caller already has.
///
/// **This is the one place a row's points become a chart's points**, and it
/// is in the core because a host that resampled for itself would be
/// deciding how much of the history is real. A cell a row has no reading
/// for holds the last figure it had -- a gap is not a fall to zero. A cell
/// before the row's first point is zero: it was not there.
pub fn resample(points: []const Point, step_s: u32, out: []u32) void {
    @memset(out, 0);
    if (points.len == 0 or out.len == 0 or step_s == 0) return;
    const newest = points[points.len - 1].at_s;
    var k: usize = 0;
    for (out, 0..) |*c, j| {
        const back: u32 = @intCast(out.len - 1 - j);
        const moment = newest -| back *| step_s;
        var v: u32 = 0;
        while (k < points.len and points[k].at_s <= moment) : (k += 1) v = points[k].mem_mib;
        c.* = v;
    }
}

fn pushMachine(self: *Overall, now_ms: i64, at_s: u32) void {
    if (self.machine.swap_used) |sw| {
        const point: Point = .{ .at_s = at_s, .mem_mib = @intCast(@min(sw / mib, std.math.maxInt(u32))), .cpu_ds = 0 };
        if (@divFloor(now_ms, hour_ms) != self.swap_hour_cell) {
            self.swap_hour_cell = @divFloor(now_ms, hour_ms);
            self.swap_hour_ring.push(&self.swap_hour, point);
        }
        if (@divFloor(now_ms, week_ms) != self.swap_week_cell) {
            self.swap_week_cell = @divFloor(now_ms, week_ms);
            self.swap_week_ring.push(&self.swap_week, point);
        }
    }
    if (self.machine.disk_free) |free| {
        // The ring keeps *free* space, so a fall is the reading that
        // matters; the verdict is `diskLow`, which is a line rather than a
        // rise.
        const point: Point = .{ .at_s = at_s, .mem_mib = @intCast(@min(free / mib, std.math.maxInt(u32))), .cpu_ds = 0 };
        if (@divFloor(now_ms, hour_ms) != self.disk_hour_cell) {
            self.disk_hour_cell = @divFloor(now_ms, hour_ms);
            self.disk_hour_ring.push(&self.disk_hour, point);
        }
        if (@divFloor(now_ms, week_ms) != self.disk_week_cell) {
            self.disk_week_cell = @divFloor(now_ms, week_ms);
            self.disk_week_ring.push(&self.disk_week, point);
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn at(s: u32, mem: u32) Point {
    return .{ .at_s = s, .mem_mib = mem, .cpu_ds = 0 };
}

/// `n` points a minute apart from `from`, moving `step` each.
fn series(out: []Point, n: usize, from: i64, step: i64) []Point {
    for (out[0..n], 0..) |*p, i| {
        p.* = at(@intCast(i * 60), @intCast(@max(0, from + @as(i64, @intCast(i)) * step)));
    }
    return out[0..n];
}

test "2149: a steady 600 MiB an hour is rising, and 400 is not" {
    var buf: [60]Point = undefined;
    const rising = growth(series(&buf, 60, 600, 10)); // 10 MiB a minute
    try testing.expect(rising.rising);
    try testing.expect(rising.rose_mib >= thresholds.rising_mib);
    try testing.expect(rising.since_s != null);
    try testing.expect(rising.slope_mib_per_h > 500);
    try testing.expect(rising.slope_mib_per_h < 700);

    var slow_buf: [60]Point = undefined;
    const slow = growth(series(&slow_buf, 60, 600, 6)); // 6 a minute: 360 an hour
    try testing.expect(!slow.rising);
    try testing.expectEqual(@as(?u32, null), slow.since_s);
}

test "2149: 2 GB in the first minute and then level is not rising" {
    var buf: [60]Point = undefined;
    _ = series(&buf, 60, 600, 0);
    for (buf[1..]) |*p| p.mem_mib += 2048;
    const g = growth(&buf);
    try testing.expect(!g.rising);
}

test "2149: one 700 MiB step at the start of a level hour is not rising" {
    // It gained more than the line, so this is not rule 2 that stops it --
    // it is rule 4: the whole rise is one step, which is a process that
    // took its memory at startup and held it.
    var buf: [60]Point = undefined;
    _ = series(&buf, 60, 600, 0);
    for (buf[20..]) |*p| p.mem_mib += 700;
    const g = growth(&buf);
    try testing.expect(g.rose_mib >= thresholds.rising_mib);
    try testing.expect(!g.rising);
}

test "2149: 700 MiB up but with a twenty-minute fall in the middle is not rising" {
    var buf: [60]Point = undefined;
    // Up 20 a minute for twenty minutes, back down 10 a minute for twenty,
    // then up 20 again: 500 MiB over the hour, reached in no single jump,
    // and only four of the six segments rise.
    for (&buf, 0..) |*p, i| {
        const mem: i64 = switch (i) {
            0...19 => 20 * @as(i64, @intCast(i)),
            20...39 => 380 - 10 * @as(i64, @intCast(i - 19)),
            else => 180 + 20 * @as(i64, @intCast(i - 39)),
        };
        p.* = at(@intCast(i * 60), @intCast(mem));
    }
    const g = growth(&buf);
    try testing.expect(g.rose_mib >= thresholds.rising_mib);
    try testing.expect(!g.rising);
}

test "2149: a sawtooth rising 800 MiB overall is still rising" {
    var buf: [60]Point = undefined;
    for (&buf, 0..) |*p, i| {
        // Up 14 a minute with a 6 MiB sawtooth on top: the shape a
        // collecting process has.
        const wobble: i64 = if (i % 4 == 0) -6 else 0;
        p.* = at(@intCast(i * 60), @intCast(600 + @as(i64, @intCast(i)) * 14 + wobble));
    }
    const g = growth(&buf);
    try testing.expect(g.rising);
}

test "2149: thirty points are not judged at all" {
    var buf: [60]Point = undefined;
    const g = growth(series(&buf, 30, 600, 10));
    try testing.expect(!g.rising);
    try testing.expectEqual(@as(i32, 0), g.slope_mib_per_h);
    try testing.expectEqual(@as(?u32, null), g.since_s);
}

test "2149: the slope is the window's, whether or not it qualifies" {
    // 6 a minute is 360 an hour, which is not rising -- and the number a
    // card shows is still that 360.
    var buf: [60]Point = undefined;
    const g = growth(series(&buf, 60, 600, 6));
    try testing.expect(!g.rising);
    try testing.expect(g.slope_mib_per_h > 300 and g.slope_mib_per_h < 420);
}

test "2149: forty minutes of rising and twenty level is under the line" {
    var buf: [60]Point = undefined;
    _ = series(&buf, 60, 600, 10);
    for (buf[40..]) |*p| p.mem_mib = buf[39].mem_mib;
    const g = growth(&buf);
    try testing.expect(!g.rising);
    try testing.expect(g.rose_mib < thresholds.rising_mib);
}

test "2149: a hundred thousand readings hold the same bytes, so the monitor does not leak" {
    // **The point of the whole file** (handoff §0.3). Two seconds apart for
    // 100 000 readings is fifty-five hours, with processes being born,
    // dying, changing groups and changing pid -- every path a container that
    // only ever grows would grow along.
    var counter: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const alloc = counter.allocator();

    const o = try Overall.create(alloc);
    defer o.destroy();

    var panes: [16]PaneReading = undefined;
    var settled_bytes: usize = 0;
    var settled_allocs: usize = 0;

    const start_ms: i64 = 1_700_000_000_000;
    var now_ms: i64 = start_ms;
    for (0..100_000) |i| {
        const live = (i / 37) % 16;
        for (panes[0..live], 0..) |*p, k| {
            const seed: u32 = @intCast((i / 13 + k) % 24);
            p.* = .{
                .id = 0x100 + k,
                .root_pid = 2000 + seed,
                .mem = (100 + seed * 7) * mib,
                .procs = 2 + seed,
                .cpu_ns = 1_000_000 * seed,
                .sidecar_mem = if (seed % 2 == 0) 20 * mib else 0,
                .sidecar_procs = if (seed % 2 == 0) 1 else 0,
                .sidecar_pid = 5000 + seed,
            };
            if ((i / 11 + k) % 3 == 0) {
                const n = @min("web-app".len, p.group.len);
                @memcpy(p.group[0..n], "web-app"[0..n]);
                p.group_len = @intCast(n);
                p.kind = .chat;
            }
        }
        o.sample(.{
            .now_ms = now_ms,
            .start_ms = start_ms,
            .machine = .{
                .mem_total = 32 << 30,
                .mem_used = (20 + i % 7) << 30,
                .swap_used = (4 << 30) + i * mib,
                .swap_total = 24 << 30,
                .disk_free = (40 << 30) -| i * (mib / 2),
            },
            .main = .{ .id = 0, .root_pid = 4242, .mem = (400 + i % 5) * mib, .procs = 12, .cpu_ns = 5_000_000 },
            .panes = panes[0..live],
        });
        now_ms += 2000;
        if (i == 999) {
            // After a thousand readings -- 33 minutes -- the rings are
            // filling as fast as the clock lets them and the eviction paths
            // have all run. **Not "every buffer has been filled and wrapped
            // at least once"**, which is what this comment used to say: the
            // hour ring holds 1440 minute points and the week ring 1008 ten
            // minute ones, so 1000 readings wrap neither. The wrapping is
            // the loop below, one reading every ten minutes.
            settled_bytes = counter.allocated_bytes - counter.freed_bytes;
            settled_allocs = counter.allocations;
        }
    }

    try testing.expectEqual(settled_bytes, counter.allocated_bytes - counter.freed_bytes);
    // And nothing was taken after the first: the whole structure is the one
    // allocation `create` took. This is the line the floor test reds at.
    try testing.expectEqual(@as(usize, 1), counter.allocations);
    try testing.expectEqual(settled_allocs, counter.allocations);
    try testing.expect(o.trackedCount() <= max_tracked);
    try testing.expect(o.monitorBytes() > 1 << 20);
    try testing.expectEqual(@as(u64, @sizeOf(Overall)), o.monitorBytes());

    // **A reading every ten minutes until the week ring has gone round**,
    // which the two-second loop above cannot reach: it would take 302 400
    // of them. The point is that the last container to fill is bounded too,
    // and that a wrapped week costs no allocation either.
    for (0..week_cap + 20) |_| {
        o.sample(.{
            .now_ms = now_ms,
            .start_ms = start_ms,
            .machine = .{ .mem_total = 32 << 30, .mem_used = 20 << 30, .swap_used = 6 << 30, .swap_total = 24 << 30, .disk_free = 30 << 30 },
            .main = .{ .id = 0, .root_pid = 4242, .mem = 400 * mib, .procs = 12 },
        });
        now_ms += week_ms;
    }
    try testing.expectEqual(@as(usize, 1), counter.allocations);
    try testing.expectEqual(settled_bytes, counter.allocated_bytes - counter.freed_bytes);
    const main = o.slotOfKind(.main).?;
    try testing.expectEqual(@as(u16, week_cap), o.slotAt(main).week_ring.len);
    try testing.expectEqual(@as(u16, hour_cap), o.slotAt(main).hour_ring.len);
}

test "2149: a terminal that keeps its pane keeps its row, though its pid moves" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();

    const start_ms: i64 = 1_700_000_000_000;
    var chat = PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    chat.root_pid = 100;
    chat.start_ms = start_ms - 5_000;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    const row = o.slotOfKind(.chat).?;
    try testing.expectEqualStrings("web-app", o.groupOf(row));
    try testing.expectEqual(@as(?u8, row), o.rowOfPid(100));

    // **The pid alone is not another process.** A pid is reused by the
    // system and moves between two processes of the same shape; the moment
    // the process started is what says whether this is the same one. Here
    // it is: the same row, the same curve, a different pid.
    var rot = chat;
    rot.root_pid = 999;
    o.sample(.{ .now_ms = start_ms + 60_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{rot} });
    try testing.expectEqual(row, o.slotOfKind(.chat).?);
    try testing.expectEqual(@as(u32, 999), o.slotAt(row).pid);
    try testing.expectEqual(@as(u16, 2), o.slotAt(row).hour_ring.len);
    try testing.expectEqual(@as(?u8, row), o.rowOfPid(999));
    try testing.expectEqual(@as(?u8, null), o.rowOfPid(100));

    // **A process that started at another moment is another process**: the
    // same terminal, the same group, and the curve starts again (handoff
    // §4 rule 7).
    var replaced = chat;
    replaced.root_pid = 999;
    replaced.start_ms = start_ms + 60_000;
    o.sample(.{ .now_ms = start_ms + 120_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{replaced} });
    try testing.expectEqual(row, o.slotOfKind(.chat).?);
    try testing.expectEqual(@as(u16, 1), o.slotAt(row).hour_ring.len);
}

test "2149: a row nothing names for a day goes, and the main process never does" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();

    const start_ms: i64 = 1_700_000_000_000;
    const chat = PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    // The chat is gone on the next reading; its row stays for the morning.
    o.sample(.{ .now_ms = start_ms + 2000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib } });
    try testing.expect(o.slotOfKind(.chat) != null);
    // A day later it is dropped.
    o.sample(.{ .now_ms = start_ms + keep_dead_ms + 4000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib } });
    try testing.expectEqual(@as(?u8, null), o.slotOfKind(.chat));
    try testing.expect(o.slotOfKind(.main) != null);
    try testing.expect(o.slotOfKind(.monitor) != null);
}

test "2149: the main process, its chats and its sidecars all add up" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();

    const start_ms: i64 = 1_700_000_000_000;
    const chat = PaneReading.named(0xab, .chat, "web-app", 20 << 30, 3);
    const worker = PaneReading{ .id = 0xcd, .kind = .worker, .mem = 3 << 30, .procs = 30, .sidecar_mem = 200 * mib, .sidecar_procs = 2, .sidecar_pid = 77 };
    o.sample(.{
        .now_ms = start_ms,
        .start_ms = start_ms,
        .main = .{ .id = 0, .root_pid = 1, .mem = 500 * mib, .procs = 12 },
        .panes = &.{ chat, worker },
    });
    try testing.expectEqual(@as(?u8, 0), o.slotOfKind(.main));
    const sidecar = o.slotOfKind(.sidecar).?;
    try testing.expectEqual(@as(u32, 2), o.slotAt(sidecar).count);
    try testing.expectEqual(@as(u32, 77), o.slotAt(sidecar).pid);
    try testing.expectEqualStrings("", o.groupOf(sidecar));
    try testing.expectEqualStrings("web-app", o.groupOf(o.slotOfKind(.chat).?));
    // Everything tracked adds up, the monitor's own row included.
    const monitor_mib: u64 = @max(1, o.monitorBytes() / mib);
    try testing.expectEqual(@as(u64, 500 + (20 << 10) + 200), o.totalMib() - monitor_mib);
}

test "2149: the disk is judged by a line, not by a rise" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .mem = mib }, .machine = .{ .disk_free = 40 << 30 } });
    try testing.expect(!o.diskLow());
    o.sample(.{ .now_ms = start_ms + 2000, .start_ms = start_ms, .main = .{ .id = 0, .mem = mib }, .machine = .{ .disk_free = (thresholds.disk_low_mib - 1) * mib } });
    try testing.expect(o.diskLow());
}

test "2149: a process using half a core reads as half a core, not as its lifetime total" {
    // **CPU is a rate.** `cpu_ns` is CPU time since the process started, and
    // reading it as "tenths of a core" made an hour-old main process show
    // 1802 cores -- and made every row's CPU climb for ever, so the rising
    // test came out true for anything that had ever run. The figure is the
    // difference across the interval, divided by it.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    const ns_per_ms: u64 = std.time.ns_per_ms;

    // An hour of CPU already behind it, as a long-lived process has.
    var main: PaneReading = .{ .id = 0, .root_pid = 1, .mem = 100 * mib, .procs = 1, .cpu_ns = 3600 * 1000 * ns_per_ms };
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = main });
    // The first reading has nothing to measure from: zero says "not
    // measured", which is not the same as "no CPU".
    const row = o.slotOfKind(.main).?;
    try testing.expectEqual(@as(u32, 0), o.slotAt(row).cpu_ds);

    // Half a core for two seconds: 1 s of CPU in 2 s of wall time, over
    // four readings half a second apart, 250 ms each.
    var k: u64 = 1;
    while (k <= 4) : (k += 1) {
        main.cpu_ns = 3600 * 1000 * ns_per_ms + k * 250 * ns_per_ms;
        o.sample(.{ .now_ms = start_ms + @as(i64, @intCast(k)) * 500, .start_ms = start_ms, .main = main });
    }
    // 500 ms of wall time, 250 ms of CPU: half a core, which is 5 tenths.
    try testing.expectEqual(@as(u32, 5), o.slotAt(row).cpu_ds);

    // **And it does not climb with the total.** An hour later, having used
    // another half hour of CPU, the same process at the same rate still
    // reads half a core -- the figure is the interval's, not the process's.
    // (Read as a total it would be 108 000 tenths by now.)
    main.cpu_ns = 3600 * 1000 * ns_per_ms + 1800 * 1000 * ns_per_ms;
    o.sample(.{ .now_ms = start_ms + 3_600_000, .start_ms = start_ms, .main = main });
    main.cpu_ns += 250 * ns_per_ms;
    o.sample(.{ .now_ms = start_ms + 3_600_000 + 500, .start_ms = start_ms, .main = main });
    try testing.expectEqual(@as(u32, 5), o.slotAt(row).cpu_ds);
    try testing.expectEqual(@as(u32, 5), o.slotAt(row).hour_ring.newest(&o.hour[row]).?.cpu_ds);

    // **A process replaced reads nothing for one interval**, not a wild
    // number: the old process's total is not this one's starting point.
    main.cpu_ns = 1000 * ns_per_ms;
    main.start_ms = start_ms + 3_600_000 + 500;
    o.sample(.{ .now_ms = start_ms + 3_600_000 + 1000, .start_ms = start_ms, .main = main });
    try testing.expectEqual(@as(u32, 0), o.slotAt(row).cpu_ds);
    // And from there it measures again: the same half a core.
    main.cpu_ns = 1000 * ns_per_ms + 250 * ns_per_ms;
    o.sample(.{ .now_ms = start_ms + 3_600_000 + 1500, .start_ms = start_ms, .main = main });
    try testing.expectEqual(@as(u32, 5), o.slotAt(row).cpu_ds);
}

/// `n` readings a minute apart of a chat gaining `step` MiB a minute, taken
/// the way the app takes them: through `sample`, and asked afterwards for a
/// verdict through `growthOf`.
///
/// **The production path, not `growth` directly.** The seven rules are
/// tested above by handing `growth` sixty points; that is the function's
/// own test and it says nothing about what a row's answer is, because the
/// points have to get into the row's ring and back out through the buffer
/// `growthOf` reads them into. They did not: the buffer was `min_points`
/// long, so the hour that was judged was 49 minutes of it, and a row
/// gaining a steady 600 MiB an hour -- the handoff's own example of
/// "rising" -- answered "no".
fn climbChat(overall: *Overall, readings: usize, step_mib: u32) void {
    const start_ms: i64 = 1_700_000_000_000;
    for (0..readings) |i| {
        var chat = PaneReading.named(
            0xab,
            .chat,
            "web-app",
            @as(u64, 600 + @as(u64, @intCast(i)) * step_mib) * mib,
            3,
        );
        chat.root_pid = 100;
        chat.start_ms = start_ms - 1_000;
        overall.sample(.{
            .now_ms = start_ms + @as(i64, @intCast(i)) * hour_ms,
            .start_ms = start_ms,
            .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib },
            .panes = &.{chat},
        });
    }
}

test "2149: a chat gaining 600 MiB an hour for ninety minutes is rising, through the row" {
    // **The reading the review found wrong, taken the way the app takes
    // it.** Ninety minutes, so that the last hour of it is a full hour
    // however the row's first point fell, and asked through `growthOf`.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    climbChat(o, 90, 10); // 10 MiB a minute: 600 an hour

    const row = o.slotOfKind(.chat).?;
    const g = o.growthOf(row);
    try testing.expect(g.rising);
    try testing.expect(g.rose_mib >= thresholds.rising_mib);
    try testing.expect(g.slope_mib_per_h > 500);
    try testing.expect(g.slope_mib_per_h < 700);
    try testing.expect(g.since_s != null);

    // And the hour it judged is an hour, not 49 minutes of one. Counted the
    // way `growth` counts it: the points within `window_s` of the newest.
    var buf: [thresholds.window_points]Point = undefined;
    const n = o.hourPoints(row, &buf);
    const newest = buf[n - 1].at_s;
    var inside: usize = 0;
    var oldest: u32 = newest;
    for (buf[0..n]) |p| {
        if (newest - p.at_s > thresholds.window_s) continue;
        inside += 1;
        oldest = @min(oldest, p.at_s);
    }
    // A minute apart: 61 points is an hour and its near end. With the
    // 50-point buffer this was 50, which is 49 minutes.
    try testing.expect(inside >= 61);
    try testing.expect(newest - oldest >= thresholds.window_s - 60);
}

test "2149: a window of 54 points is judged from the points it has" {
    // **The segment rule with fewer than ten points a segment.** The window
    // is 51 to 59 points whenever a reading was missed or a row has just
    // started, and then a segment is 8 or 9 points and each half is four --
    // which is the case the buffer this rule used to read was too short
    // for: it held five slots, four were written, and the median was taken
    // over five.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    // 14 MiB a minute. **Not 10**: 54 points span 53 minutes, and rule 2
    // asks the window to have gained 500 MiB -- which 53 minutes of 10 a
    // minute does not (490), so that climb is correctly *not* rising and
    // would test the rule above instead of this one.
    climbChat(o, 54, 14);
    const row = o.slotOfKind(.chat).?;

    // The window really is 54 points, so `growth` cuts 9-point segments.
    var buf: [thresholds.window_points]Point = undefined;
    const n = o.hourPoints(row, &buf);
    try testing.expectEqual(@as(usize, 54), n);
    try testing.expectEqual(@as(usize, 9), n / thresholds.segments);
    try testing.expectEqual(@as(usize, 4), (n / thresholds.segments) / 2);

    // And the verdict is the one the amount asks for, not one a fourth
    // unread slot decided.
    const g = o.growthOf(row);
    try testing.expect(g.rising);
    try testing.expect(g.slope_mib_per_h > 700 and g.slope_mib_per_h < 1000);
}

test "2149: a segment shorter than ten points is judged from the points it has" {
    // **54 points, so `growth` cuts six segments of nine.** A segment's two
    // halves are four points each, and every median is taken over the four
    // -- not over five, of which the fifth was whatever the buffer happened
    // to hold. This series separates the two answers on purpose: each
    // segment runs base, +30, +60, +90 and then holds at +50, so the head's
    // four points have a median of `base+45` and the tail's `base+50` --
    // rising, but only by five. A fifth, unread slot lands in the sorted
    // buffer above every real value and drags the head's median up to
    // `base+60`, turning every segment's rise into a fall and the whole
    // hour into "not rising".
    var pts: [54]Point = undefined;
    for (&pts, 0..) |*p, i| {
        const seg = i / 9;
        const k = i % 9;
        const base: u32 = @intCast(1000 + seg * 126);
        const v: u32 = switch (k) {
            0 => base,
            1 => base + 30,
            2 => base + 60,
            3 => base + 90,
            else => base + 50,
        };
        p.* = at(@intCast(i * 60), v);
    }
    const g = growth(&pts);
    // The hour gained 630 MiB, in no single jump, and every segment rose.
    try testing.expectEqual(@as(u32, 630), g.rose_mib);
    try testing.expect(g.rising);
    try testing.expect(g.since_s != null);

    // The negative control: the same hour's worth of gain, reached by a
    // step up and a fall back inside every segment. Both the amount and the
    // widest single step are the ones the test above has, so what stops it
    // is rule 3 alone.
    var stepwise: [54]Point = undefined;
    for (&stepwise, 0..) |*p, i| {
        const base: u32 = @intCast(1000 + (i / 9) * 126);
        const k: u32 = @intCast(i % 9);
        p.* = at(@intCast(i * 60), base + if (k < 4) k * 30 else 0);
    }
    const down = growth(&stepwise);
    // The window's first five points have a median of base+30 and its last
    // five base+0 ... which is *under* rule 2's line, so this control stops
    // at the amount rather than at rule 3. What it shows is that the same
    // hour, judged the same way, is refused when its segments fall -- and
    // it is the amount, not the buffer, that it is refused for.
    try testing.expect(!down.rising);
    try testing.expect(!growth(&stepwise).rising);
}

test "2149: a chat gaining 400 MiB an hour for ninety minutes is not rising, through the row" {
    // The other half of the pair: the same path, the same length, and the
    // answer the handoff says it should be -- so the test above is about
    // the amount and not about the path being generous.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    climbChat(o, 90, 6); // 6 a minute: 360 an hour
    const g = o.growthOf(o.slotOfKind(.chat).?);
    try testing.expect(!g.rising);
}

test "2149: what one reading could not track is not what every reading has" {
    // The table's last line says "another N are not tracked", which is a
    // fact about the picture in front of the reader. Counted up, it was a
    // fact about the night: every reading that had to drop a row added to
    // it and nothing ever took one off.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;

    // The main process, the monitor, and a chat for every slot left.
    var chats: [max_tracked]PaneReading = undefined;
    for (&chats, 0..) |*c, i| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "g{d}", .{i}) catch unreachable;
        c.* = PaneReading.named(0x1000 + i, .chat, name, 100 * mib, 2);
        c.root_pid = @intCast(5000 + i);
        c.start_ms = start_ms - 1_000;
    }
    // Exactly what fits: 64 slots, less the main process's and the monitor's.
    const fitting = chats[0 .. max_tracked - 2];
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = fitting });
    try testing.expectEqual(@as(u32, 0), o.untracked);

    // Two chats more than there is room for: two rows are dropped, this
    // time. Not evicted -- every row in the table is alive and a chat is
    // not what gets thrown away for another chat.
    o.sample(.{ .now_ms = start_ms + 60_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &chats });
    try testing.expectEqual(@as(u32, 2), o.untracked);

    // The same reading again: still two. Not four, and not "two for ever".
    o.sample(.{ .now_ms = start_ms + 120_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &chats });
    try testing.expectEqual(@as(u32, 2), o.untracked);

    // And a reading that fits drops it back: nothing is not tracked now.
    o.sample(.{ .now_ms = start_ms + 180_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = fitting });
    try testing.expectEqual(@as(u32, 0), o.untracked);
}

test "2149: a group renamed takes its rows and their history with it" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    var chat = PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    chat.root_pid = 100;
    chat.start_ms = start_ms - 1_000;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    o.sample(.{ .now_ms = start_ms + 60_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    const row = o.slotOfKind(.chat).?;
    try testing.expectEqual(@as(u16, 2), o.slotAt(row).hour_ring.len);

    // **The chat's own arguments still say the old name** -- the surface
    // the control room started has not been started again -- so the next
    // readings go on saying `web-app` and the rename has to hold.
    o.renameGroup("web-app", "billing");
    try testing.expectEqualStrings("billing", o.groupOf(row));
    try testing.expectEqual(@as(u16, 2), o.slotAt(row).hour_ring.len);

    // **And it still holds after the next reading.** This is the line the
    // review's repro red at: `touch` used to copy the arguments' name in
    // every time, so the new name lasted two seconds. Two more readings,
    // both still carrying the old name in the arguments.
    o.sample(.{ .now_ms = start_ms + 120_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    try testing.expectEqualStrings("billing", o.groupOf(row));
    o.sample(.{ .now_ms = start_ms + 180_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    try testing.expectEqualStrings("billing", o.groupOf(row));
    try testing.expectEqual(@as(u16, 4), o.slotAt(row).hour_ring.len);

    // **A chat restarted under another `--group=` is another group**, and
    // that is the one thing the arguments may still move: the surface was
    // started again, for a group that is not the one the row was renamed
    // to.
    var moved = PaneReading.named(0xab, .chat, "infra", 2 << 30, 3);
    moved.root_pid = 100;
    moved.start_ms = chat.start_ms;
    o.sample(.{ .now_ms = start_ms + 240_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{moved} });
    try testing.expectEqualStrings("infra", o.groupOf(row));

    // A name that is no row's changes nothing.
    o.renameGroup("nobody", "somebody");
    try testing.expectEqualStrings("infra", o.groupOf(row));
}

test "2149: a group deleted takes its rows with it, now and not in a day" {
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    var chat = PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    chat.root_pid = 100;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    try testing.expect(o.slotOfKind(.chat) != null);

    o.forgetGroup("web-app");
    // The row is gone at once. Left to the 24 hours a dead row is kept for,
    // the process table would go on listing a group nobody has.
    try testing.expectEqual(@as(?u8, null), o.slotOfKind(.chat));
    try testing.expectEqual(@as(?u8, null), o.rowOfPid(100));
    try testing.expect(o.slotOfKind(.main) != null);
}

test "2149: a sidecar row keeps its history when the sidecar it names changes" {
    // A pane with two `polter +mcp` processes: which of them the row names
    // is whichever started first, and if that one goes the next is named.
    // **The row is the terminal's sidecars**, so its curve is theirs
    // together and is not thrown away when the name moves -- a row being
    // watched for a leak that lost its history every few minutes would
    // never have enough points to be judged at all.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;

    const first = PaneReading{
        .id = 0xcd,
        .kind = .worker,
        .mem = 3 << 30,
        .procs = 30,
        .sidecar_mem = 200 * mib,
        .sidecar_procs = 2,
        .sidecar_pid = 77,
    };
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{first} });
    const row = o.slotOfKind(.sidecar).?;
    try testing.expectEqual(@as(u32, 77), o.slotAt(row).pid);

    // The other sidecar is named now (the first went): the same row, the
    // same curve.
    var second = first;
    second.sidecar_pid = 91;
    o.sample(.{ .now_ms = start_ms + 60_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{second} });
    try testing.expectEqual(row, o.slotOfKind(.sidecar).?);
    try testing.expectEqual(@as(u32, 91), o.slotAt(row).pid);
    try testing.expectEqual(@as(u16, 2), o.slotAt(row).hour_ring.len);
    try testing.expectEqual(@as(?u8, row), o.rowOfPid(91));
    try testing.expectEqual(@as(?u8, null), o.rowOfPid(77));
}

test "2149: the answer says which rows are dead, and when they went" {
    // The morning after: a row nothing names any more is still listed, and
    // the reader has to be able to tell it from a live one -- otherwise a
    // process that died at 03:00 reads as one that is running now.
    var o = try Overall.create(testing.allocator);
    defer o.destroy();
    const start_ms: i64 = 1_700_000_000_000;
    var chat = PaneReading.named(0xab, .chat, "web-app", 2 << 30, 3);
    chat.root_pid = 100;
    o.sample(.{ .now_ms = start_ms, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib }, .panes = &.{chat} });
    const row = o.slotOfKind(.chat).?;
    try testing.expect(o.slotAt(row).alive);

    o.sample(.{ .now_ms = start_ms + 60_000, .start_ms = start_ms, .main = .{ .id = 0, .root_pid = 1, .mem = 100 * mib } });
    try testing.expect(!o.slotAt(row).alive);
    try testing.expectEqual(start_ms + 60_000, o.slotAt(row).died_ms);
    // And the reading before it is still readable: this is the row's last
    // figure, which is what a dead row shows.
    try testing.expectEqual(@as(u32, 2048), o.slotAt(row).mem_mib);
}
