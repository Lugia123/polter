//! Counting what a night was, so the panel can show it.
//!
//! Kept apart from the drawing for the reason `chat_layout.zig` is: what is
//! interesting here is arithmetic over a record, and arithmetic can be
//! tested while a screen cannot. Everything in this file is a count, a
//! duration, or a sort. **Nothing here decides anything.**
//!
//! That line is the whole point of the file. A task untouched for two days
//! may be stalled or may be a standing lease that is meant to stay open --
//! the terminal holding a machine nobody else may touch is a task by
//! design, and no rule written over the record can tell those apart. So
//! this measures how long something has been still and says so, exactly
//! the way `set_quiescence_threshold` measures a screen: the number is the
//! program's, the verdict is the supervisor's. `over` below means "past
//! the mark you set", never "stuck".
//!
//! See `docs/poltergeist/stats.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One thing that happened to one task, as `task_history` hands it over.
///
/// The words stay words: an `op` this build has never heard of is counted
/// under none of the five and shown as itself, which is the same choice
/// the panel makes about `progress`.
pub const Event = struct {
    seq: u64,
    at_ms: i64,
    op: []const u8,
    task: u64,
    title: []const u8,

    /// The `0x…` text, the way every id crosses this socket.
    owner: []const u8,
    state: []const u8,
    progress: []const u8,
};

/// One task as the panel holds it now.
pub const Task = struct {
    id: u64,
    title: []const u8,
    owner: []const u8,
    state: []const u8,
};

/// One message, reduced to the two things a count needs.
pub const Message = struct {
    at_ms: i64,

    /// Who said it. The user's own messages arrive with no id, and are
    /// counted as the user rather than dropped: "nobody said 312 things"
    /// is a worse answer than naming the person at the keyboard.
    author: []const u8,
    from_user: bool,
};

pub const Member = struct {
    id: []const u8,
    title: []const u8,
};

/// Turning a wall-clock instant into a local hour of the day.
///
/// Injected the way `chat_layout.Measure` is, and for the same reason: the
/// real one goes through `localtime_r`, which depends on the machine's zone
/// and on the hour the test happens to run. A test that had to guess at
/// either would be a test of the clock.
pub const HourOf = *const fn (at_ms: i64) u8;

pub const Input = struct {
    now_ms: i64,

    /// How long a task has to have been untouched before it is marked.
    ///
    /// **A mark, not a judgement.** See the file comment.
    stale_ms: u64,

    events: []const Event,
    tasks: []const Task,
    messages: []const Message,
    members: []const Member,
    hour_of: HourOf,
};

/// One open task and how long since anything happened to it.
pub const Waiting = struct {
    task: u64,
    title: []const u8,
    owner: []const u8,
    silent_ms: u64,

    /// Past the mark. Not "stuck": see the file comment.
    over: bool,

    /// Ordered by silence, longest first -- the order a person reads this
    /// list in, and the only ordering that does not imply a ranking of the
    /// terminals themselves.
    fn quietestFirst(_: void, a: Waiting, b: Waiting) bool {
        if (a.silent_ms != b.silent_ms) return a.silent_ms > b.silent_ms;
        return a.task < b.task;
    }
};

/// What one terminal said and what it was given.
///
/// Two columns rather than one sorted list, because a single number
/// ordered by size reads as a scoreboard. Side by side, the pair is a
/// question -- somebody who says a great deal and holds nothing, or holds
/// a great deal and says nothing, is worth a look -- and the question is
/// the supervisor's to answer.
pub const Speaker = struct {
    id: []const u8,
    title: []const u8,
    said: usize,
    doing: usize,

    fn loudestFirst(_: void, a: Speaker, b: Speaker) bool {
        if (a.said != b.said) return a.said > b.said;
        return a.doing > b.doing;
    }
};

/// The shape of the whole session.
pub const Session = struct {
    /// The first message's clock, which is as close to "when this group
    /// started" as anything gets without a new field to store it in.
    /// Zero when nothing was ever said.
    started_ms: i64 = 0,

    messages: usize = 0,
    created: usize = 0,
    closed: usize = 0,
    cancelled: usize = 0,

    /// Still open, counted off the panel rather than off the events, so a
    /// record that lost its tail still gives the right number.
    open: usize = 0,

    /// Tasks that were handed out more than once.
    reassigned: usize = 0,

    /// How many progress reports there were, against how many tasks there
    /// are. The pair is the point: 24 reports across 71 tasks says most
    /// tasks never reported, which a bar chart of progress states would
    /// have drawn as "everybody is queued".
    progressed: usize = 0,
    tasks_total: usize = 0,
};

/// How long tasks lived, for the ones that finished.
pub const Life = struct {
    /// The bars, oldest-scale left: bucket `i` counts tasks whose life
    /// fell in the `i`th slice between `fastest_ms` and `slowest_ms`.
    buckets: [buckets_len]u16 = @splat(0),

    fastest_ms: u64 = 0,
    median_ms: u64 = 0,
    slowest_ms: u64 = 0,

    /// How many tasks this is over. Under two, the spread means nothing
    /// and the drawing says the numbers instead.
    counted: usize = 0,

    pub const buckets_len = 24;
};

/// When the talking happened, by local hour.
pub const Rhythm = struct {
    hours: [24]u32 = @splat(0),
    busiest: u8 = 0,
    busiest_count: u32 = 0,
};

/// Where the conversation stopped, and for how long.
pub const Silence = struct {
    /// Since the last message. This is the number that answers "is
    /// anything happening" at the end of the night.
    since_last_ms: u64 = 0,

    /// The longest run with nothing said in it, and when it began.
    longest_ms: u64 = 0,
    longest_from_ms: i64 = 0,

    /// One cell per half hour over the last day, newest at the right.
    /// True where something was said in that half hour.
    day: [day_cells]bool = @splat(false),

    pub const day_cells = 48;
    pub const cell_ms: i64 = 30 * 60 * 1000;
};

/// Who is here now, and who has ever been.
pub const Terminals = struct {
    now: usize = 0,

    /// Every id that appears in the members list, in a message, or as a
    /// task's owner. The union, because a terminal that talked all night
    /// and has since closed is part of what happened.
    ever: usize = 0,
};

pub const Stats = struct {
    waiting: []const Waiting,
    speakers: []const Speaker,
    session: Session,
    life: Life,
    rhythm: Rhythm,
    silence: Silence,
    terminals: Terminals,

    /// Everything above was built in one arena, which is what this frees.
    /// The strings are borrowed from the caller's own store and are not
    /// freed here.
    pub fn deinit(self: *Stats, alloc: Allocator) void {
        alloc.free(self.waiting);
        alloc.free(self.speakers);
        self.* = undefined;
    }
};

/// The id the panel writes when a task belongs to nobody.
pub const nobody = "0x0000000000000000";

/// The user's own id. `Surface.id` is never zero, so this is only ever the
/// person at the keyboard.
pub const user_id = "0x0000000000000000";

pub fn compute(alloc: Allocator, in: Input) Allocator.Error!Stats {
    return .{
        .waiting = try waiting(alloc, in),
        .speakers = try speakers(alloc, in),
        .session = session(in),
        .life = life(in),
        .rhythm = rhythm(in),
        .silence = silence(in),
        .terminals = try terminals(alloc, in),
    };
}

/// The open tasks, longest silence first.
///
/// Silence is measured from the task's own last event, not from the last
/// message: a supervisor talking about a task is not the task moving, and
/// conflating the two is how a busy group hides a task nobody has touched.
fn waiting(alloc: Allocator, in: Input) Allocator.Error![]const Waiting {
    var out: std.ArrayListUnmanaged(Waiting) = .empty;
    errdefer out.deinit(alloc);

    for (in.tasks) |t| {
        if (!std.mem.eql(u8, t.state, "open")) continue;

        // The last event for this task, whatever it was.
        //
        // Optional rather than a zero: zero is a real instant, and a
        // sentinel that is also a value is how a task stamped at the epoch
        // -- which is what an unset clock writes -- would be read as
        // having no record at all.
        var last: ?i64 = null;
        for (in.events) |e| {
            if (e.task != t.id) continue;
            if (last == null or e.at_ms > last.?) last = e.at_ms;
        }

        // No event at all means the record does not reach back this far --
        // the log was off, or the task is older than the record. Silence
        // of zero would put it at the bottom of the list looking freshly
        // touched, which is a claim; leaving it out is not.
        const touched = last orelse continue;

        const silent: u64 = if (in.now_ms > touched)
            @intCast(in.now_ms - touched)
        else
            0;

        try out.append(alloc, .{
            .task = t.id,
            .title = t.title,
            .owner = t.owner,
            .silent_ms = silent,
            .over = silent >= in.stale_ms,
        });
    }

    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(Waiting, items, {}, Waiting.quietestFirst);
    return items;
}

/// Said and doing, per terminal, loudest first.
fn speakers(alloc: Allocator, in: Input) Allocator.Error![]const Speaker {
    var out: std.ArrayListUnmanaged(Speaker) = .empty;
    errdefer out.deinit(alloc);

    // The members list is the only place an id has a name, so it is what
    // this walks. A terminal that has since closed keeps whatever name it
    // used in the messages; see below.
    for (in.members) |m| {
        var said: usize = 0;
        for (in.messages) |msg| {
            if (msg.from_user and std.mem.eql(u8, m.id, user_id)) {
                said += 1;
                continue;
            }
            if (!msg.from_user and std.mem.eql(u8, msg.author, m.title)) said += 1;
        }

        // Distinct tasks, not assignments: a task handed back and given
        // again is one thing this terminal was asked to do, and counting
        // the handovers would make the terminal that was messed about look
        // like the busiest one in the group.
        var doing: usize = 0;
        for (in.tasks) |t| {
            if (std.mem.eql(u8, t.owner, m.id)) doing += 1;
        }

        try out.append(alloc, .{
            .id = m.id,
            .title = m.title,
            .said = said,
            .doing = doing,
        });
    }

    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(Speaker, items, {}, Speaker.loudestFirst);
    return items;
}

fn session(in: Input) Session {
    var s: Session = .{
        .messages = in.messages.len,
        .tasks_total = in.tasks.len,
    };

    if (in.messages.len > 0) s.started_ms = in.messages[0].at_ms;

    for (in.tasks) |t| {
        if (std.mem.eql(u8, t.state, "open")) s.open += 1;
    }

    // Counted over events rather than over the panel, because the panel
    // holds one state per task and the question here is how many times
    // each thing happened.
    var seen: [64]struct { task: u64, assigns: u16 } = undefined;
    var seen_len: usize = 0;

    for (in.events) |e| {
        if (std.mem.eql(u8, e.op, "created")) s.created += 1;
        if (std.mem.eql(u8, e.op, "closed")) s.closed += 1;
        if (std.mem.eql(u8, e.op, "cancelled")) s.cancelled += 1;
        if (std.mem.eql(u8, e.op, "progressed")) s.progressed += 1;

        if (!std.mem.eql(u8, e.op, "assigned")) continue;

        // A small fixed table rather than a map: this is called on every
        // frame the tab is showing, and a night is tens of tasks. Past the
        // table the count simply stops growing, which understates rather
        // than invents -- and the number it is used for is "how many were
        // handed round", where a floor is honest and a wrong figure is
        // not.
        var found = false;
        for (seen[0..seen_len]) |*row| {
            if (row.task != e.task) continue;
            row.assigns += 1;
            if (row.assigns == 2) s.reassigned += 1;
            found = true;
            break;
        }
        if (!found and seen_len < seen.len) {
            seen[seen_len] = .{ .task = e.task, .assigns = 1 };
            seen_len += 1;
        }
    }

    return s;
}

/// How long the finished tasks lived.
///
/// Only the ones with both ends in the record. A task whose `created` fell
/// off the front would otherwise measure from whenever the record happens
/// to start, which is a number about the record rather than about the work.
fn life(in: Input) Life {
    var out: Life = .{};

    var lives: [256]u64 = undefined;
    var n: usize = 0;

    for (in.events) |e| {
        if (!std.mem.eql(u8, e.op, "closed") and
            !std.mem.eql(u8, e.op, "cancelled")) continue;
        if (n >= lives.len) break;

        var born: ?i64 = null;
        for (in.events) |c| {
            if (c.task != e.task) continue;
            if (!std.mem.eql(u8, c.op, "created")) continue;
            born = c.at_ms;
            break;
        }

        // Optional for the reason `waiting` uses one: the epoch is an
        // instant like any other, and a task created at it would be read
        // as a task with no beginning in the record.
        const from = born orelse continue;
        if (e.at_ms < from) continue;

        lives[n] = @intCast(e.at_ms - from);
        n += 1;
    }

    if (n == 0) return out;

    const got = lives[0..n];
    std.mem.sort(u64, got, {}, std.sort.asc(u64));

    out.counted = n;
    out.fastest_ms = got[0];
    out.slowest_ms = got[n - 1];
    out.median_ms = if (n % 2 == 1)
        got[n / 2]
    else
        (got[n / 2 - 1] + got[n / 2]) / 2;

    // One bucket wide enough to hold everything when they all lived the
    // same length, rather than a division by zero.
    const span = out.slowest_ms - out.fastest_ms;
    if (span == 0) {
        out.buckets[0] = @intCast(@min(n, std.math.maxInt(u16)));
        return out;
    }

    for (got) |v| {
        const scaled = (v - out.fastest_ms) * (Life.buckets_len - 1) / span;
        const i: usize = @intCast(@min(scaled, Life.buckets_len - 1));
        out.buckets[i] +|= 1;
    }
    return out;
}

fn rhythm(in: Input) Rhythm {
    var out: Rhythm = .{};
    for (in.messages) |m| {
        const h = in.hour_of(m.at_ms);
        if (h > 23) continue;
        out.hours[h] +|= 1;
    }
    for (out.hours, 0..) |count, i| {
        if (count <= out.busiest_count) continue;
        out.busiest_count = count;
        out.busiest = @intCast(i);
    }
    return out;
}

/// Where the conversation stopped, and the day behind it.
///
/// Gaps are measured between consecutive messages **and** from the last
/// message to now, because the gap that matters most at three in the
/// morning is the one that has not ended yet.
fn silence(in: Input) Silence {
    var out: Silence = .{};
    if (in.messages.len == 0) return out;

    var prev: i64 = in.messages[0].at_ms;
    for (in.messages[1..]) |m| {
        if (m.at_ms > prev) {
            const gap: u64 = @intCast(m.at_ms - prev);
            if (gap > out.longest_ms) {
                out.longest_ms = gap;
                out.longest_from_ms = prev;
            }
        }
        prev = m.at_ms;
    }

    if (in.now_ms > prev) {
        out.since_last_ms = @intCast(in.now_ms - prev);
        if (out.since_last_ms > out.longest_ms) {
            out.longest_ms = out.since_last_ms;
            out.longest_from_ms = prev;
        }
    }

    // The day behind, half an hour to a cell, the newest cell on the right.
    const window = Silence.cell_ms * Silence.day_cells;
    const from = in.now_ms - window;
    for (in.messages) |m| {
        if (m.at_ms < from or m.at_ms > in.now_ms) continue;
        const cell: usize = @intCast(@divFloor(m.at_ms - from, Silence.cell_ms));
        out.day[@min(cell, Silence.day_cells - 1)] = true;
    }
    return out;
}

/// How many terminals are here, and how many have ever been.
fn terminals(alloc: Allocator, in: Input) Allocator.Error!Terminals {
    var out: Terminals = .{ .now = in.members.len };

    var ever: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ever.deinit(alloc);

    const add = struct {
        fn f(a: Allocator, list: *std.ArrayListUnmanaged([]const u8), id: []const u8) !void {
            if (id.len == 0) return;
            if (std.mem.eql(u8, id, nobody)) return;
            for (list.items) |seen| {
                if (std.mem.eql(u8, seen, id)) return;
            }
            try list.append(a, id);
        }
    }.f;

    for (in.members) |m| try add(alloc, &ever, m.id);

    // A terminal that has closed is gone from the members list but is
    // still all over the record: it owned tasks, and the events kept the
    // id even after the tab went away.
    for (in.events) |e| try add(alloc, &ever, e.owner);
    for (in.tasks) |t| try add(alloc, &ever, t.owner);

    out.ever = ever.items.len;
    return out;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A fixed hour, so a test says something about the arithmetic rather than
/// about the machine's timezone. Hour = (at_ms / one hour) % 24, which is
/// UTC and is a decision this test makes for itself.
fn testHour(at_ms: i64) u8 {
    const hours = @divFloor(at_ms, 60 * 60 * 1000);
    return @intCast(@mod(hours, 24));
}

const hour: i64 = 60 * 60 * 1000;
const minute: i64 = 60 * 1000;

test "an open task is measured from its own last event, not from the talk" {
    const alloc = testing.allocator;
    const now: i64 = 100 * hour;

    const events = [_]Event{
        .{ .seq = 1, .at_ms = 10 * hour, .op = "created", .task = 93, .title = "one", .owner = nobody, .state = "open", .progress = "queued" },
        .{ .seq = 2, .at_ms = 12 * hour, .op = "assigned", .task = 93, .title = "one", .owner = "0x1111", .state = "open", .progress = "queued" },
        .{ .seq = 3, .at_ms = 99 * hour, .op = "created", .task = 94, .title = "two", .owner = nobody, .state = "open", .progress = "queued" },
    };
    const tasks = [_]Task{
        .{ .id = 93, .title = "one", .owner = "0x1111", .state = "open" },
        .{ .id = 94, .title = "two", .owner = nobody, .state = "open" },
    };

    // Plenty of recent conversation, none of which touches task 93.
    const messages = [_]Message{
        .{ .at_ms = 99 * hour, .author = "W1", .from_user = false },
    };

    var s = try compute(alloc, .{
        .now_ms = now,
        .stale_ms = 24 * @as(u64, @intCast(hour)),
        .events = &events,
        .tasks = &tasks,
        .messages = &messages,
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), s.waiting.len);

    // Longest silence first, and the mark is set by the threshold rather
    // than by anything this file believes about the task.
    try testing.expectEqual(@as(u64, 93), s.waiting[0].task);
    try testing.expectEqual(@as(u64, 88 * @as(u64, @intCast(hour))), s.waiting[0].silent_ms);
    try testing.expect(s.waiting[0].over);

    try testing.expectEqual(@as(u64, 94), s.waiting[1].task);
    try testing.expect(!s.waiting[1].over);
}

test "a task with nothing in the record is left out rather than called fresh" {
    // Silence of zero would put it at the bottom of the list looking as if
    // somebody had just touched it, which is a claim the record cannot
    // support.
    const alloc = testing.allocator;
    const tasks = [_]Task{.{ .id = 7, .title = "old", .owner = nobody, .state = "open" }};

    var s = try compute(alloc, .{
        .now_ms = 100 * hour,
        .stale_ms = 1,
        .events = &.{},
        .tasks = &tasks,
        .messages = &.{},
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), s.waiting.len);
}

test "the session counts events by what happened, and handovers once each" {
    const alloc = testing.allocator;
    const events = [_]Event{
        .{ .seq = 1, .at_ms = hour, .op = "created", .task = 1, .title = "a", .owner = nobody, .state = "open", .progress = "queued" },
        .{ .seq = 2, .at_ms = hour, .op = "assigned", .task = 1, .title = "a", .owner = "0x1111", .state = "open", .progress = "queued" },
        .{ .seq = 3, .at_ms = 2 * hour, .op = "assigned", .task = 1, .title = "a", .owner = "0x2222", .state = "open", .progress = "queued" },
        .{ .seq = 4, .at_ms = 3 * hour, .op = "assigned", .task = 1, .title = "a", .owner = "0x3333", .state = "open", .progress = "queued" },
        .{ .seq = 5, .at_ms = 4 * hour, .op = "progressed", .task = 1, .title = "a", .owner = "0x3333", .state = "open", .progress = "working" },
        .{ .seq = 6, .at_ms = 5 * hour, .op = "created", .task = 2, .title = "b", .owner = nobody, .state = "open", .progress = "queued" },
        .{ .seq = 7, .at_ms = 6 * hour, .op = "closed", .task = 2, .title = "b", .owner = nobody, .state = "closed", .progress = "done" },
    };
    const tasks = [_]Task{
        .{ .id = 1, .title = "a", .owner = "0x3333", .state = "open" },
        .{ .id = 2, .title = "b", .owner = nobody, .state = "closed" },
    };
    const messages = [_]Message{
        .{ .at_ms = hour, .author = "W1", .from_user = false },
        .{ .at_ms = 2 * hour, .author = "W1", .from_user = false },
    };

    var s = try compute(alloc, .{
        .now_ms = 7 * hour,
        .stale_ms = 24 * @as(u64, @intCast(hour)),
        .events = &events,
        .tasks = &tasks,
        .messages = &messages,
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), s.session.created);
    try testing.expectEqual(@as(usize, 1), s.session.closed);
    try testing.expectEqual(@as(usize, 0), s.session.cancelled);
    try testing.expectEqual(@as(usize, 1), s.session.progressed);
    try testing.expectEqual(@as(usize, 1), s.session.open);
    try testing.expectEqual(@as(usize, 2), s.session.tasks_total);

    // Three assignments of one task is one task that was handed round, not
    // two and not three.
    try testing.expectEqual(@as(usize, 1), s.session.reassigned);

    try testing.expectEqual(@as(i64, hour), s.session.started_ms);
    try testing.expectEqual(@as(usize, 2), s.session.messages);
}

test "a life is measured end to end, and only when both ends are there" {
    const alloc = testing.allocator;
    const events = [_]Event{
        // Two hours.
        .{ .seq = 1, .at_ms = 0, .op = "created", .task = 1, .title = "a", .owner = nobody, .state = "open", .progress = "queued" },
        .{ .seq = 2, .at_ms = 2 * hour, .op = "closed", .task = 1, .title = "a", .owner = nobody, .state = "closed", .progress = "done" },

        // Four hours.
        .{ .seq = 3, .at_ms = hour, .op = "created", .task = 2, .title = "b", .owner = nobody, .state = "open", .progress = "queued" },
        .{ .seq = 4, .at_ms = 5 * hour, .op = "closed", .task = 2, .title = "b", .owner = nobody, .state = "closed", .progress = "done" },

        // Closed with no beginning in the record: skipped, because the
        // number would be about where the record starts.
        .{ .seq = 5, .at_ms = 6 * hour, .op = "closed", .task = 3, .title = "c", .owner = nobody, .state = "closed", .progress = "done" },
    };

    var s = try compute(alloc, .{
        .now_ms = 7 * hour,
        .stale_ms = 1,
        .events = &events,
        .tasks = &.{},
        .messages = &.{},
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), s.life.counted);
    try testing.expectEqual(@as(u64, 2 * @as(u64, @intCast(hour))), s.life.fastest_ms);
    try testing.expectEqual(@as(u64, 4 * @as(u64, @intCast(hour))), s.life.slowest_ms);
    try testing.expectEqual(@as(u64, 3 * @as(u64, @intCast(hour))), s.life.median_ms);
}

test "the longest silence includes the one that has not ended yet" {
    // Three in the morning is exactly when the gap that matters is the
    // open one, and a version that only looked between messages reported
    // the quiet spell before last.
    const alloc = testing.allocator;
    const messages = [_]Message{
        .{ .at_ms = 0, .author = "W1", .from_user = false },
        .{ .at_ms = 2 * hour, .author = "W1", .from_user = false },
        .{ .at_ms = 3 * hour, .author = "W1", .from_user = false },
    };

    var s = try compute(alloc, .{
        .now_ms = 9 * hour,
        .stale_ms = 1,
        .events = &.{},
        .tasks = &.{},
        .messages = &messages,
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(u64, 6 * @as(u64, @intCast(hour))), s.silence.since_last_ms);
    try testing.expectEqual(@as(u64, 6 * @as(u64, @intCast(hour))), s.silence.longest_ms);
    try testing.expectEqual(@as(i64, 3 * hour), s.silence.longest_from_ms);

    // The day behind: the newest cell is the right-hand one, and the three
    // messages are far enough back to leave it empty. The window opens a
    // day before now -- at -15h -- so the message at 3h lands in cell
    // (3 - -15) hours / half an hour = 36.
    try testing.expect(!s.silence.day[Silence.day_cells - 1]);
    try testing.expect(s.silence.day[36]);
}

test "the rhythm buckets by local hour and names the busiest" {
    const alloc = testing.allocator;
    const messages = [_]Message{
        .{ .at_ms = 11 * hour, .author = "W1", .from_user = false },
        .{ .at_ms = 11 * hour + 5 * minute, .author = "W1", .from_user = false },
        .{ .at_ms = 11 * hour + 9 * minute, .author = "W4", .from_user = false },
        .{ .at_ms = 14 * hour, .author = "W4", .from_user = false },
    };

    var s = try compute(alloc, .{
        .now_ms = 15 * hour,
        .stale_ms = 1,
        .events = &.{},
        .tasks = &.{},
        .messages = &messages,
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(u8, 11), s.rhythm.busiest);
    try testing.expectEqual(@as(u32, 3), s.rhythm.busiest_count);
    try testing.expectEqual(@as(u32, 1), s.rhythm.hours[14]);
}

test "said and doing are counted apart, and neither is a score" {
    const alloc = testing.allocator;
    const members = [_]Member{
        .{ .id = "0x1111", .title = "W1" },
        .{ .id = "0x2222", .title = "W4" },
        .{ .id = user_id, .title = "你" },
    };
    const messages = [_]Message{
        .{ .at_ms = hour, .author = "W1", .from_user = false },
        .{ .at_ms = hour, .author = "W1", .from_user = false },
        .{ .at_ms = hour, .author = "W4", .from_user = false },
        .{ .at_ms = hour, .author = "", .from_user = true },
    };
    const tasks = [_]Task{
        .{ .id = 1, .title = "a", .owner = "0x2222", .state = "open" },
        .{ .id = 2, .title = "b", .owner = "0x2222", .state = "closed" },
    };

    var s = try compute(alloc, .{
        .now_ms = 2 * hour,
        .stale_ms = 1,
        .events = &.{},
        .tasks = &tasks,
        .messages = &messages,
        .members = &members,
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), s.speakers.len);

    // Loudest first, and the one holding the work is not the loudest --
    // which is the mismatch the two columns exist to show.
    try testing.expectEqualStrings("W1", s.speakers[0].title);
    try testing.expectEqual(@as(usize, 2), s.speakers[0].said);
    try testing.expectEqual(@as(usize, 0), s.speakers[0].doing);

    try testing.expectEqualStrings("W4", s.speakers[1].title);
    try testing.expectEqual(@as(usize, 1), s.speakers[1].said);
    try testing.expectEqual(@as(usize, 2), s.speakers[1].doing);

    // The user's own messages arrive with no author, and are still counted
    // as somebody rather than as nobody.
    try testing.expectEqualStrings("你", s.speakers[2].title);
    try testing.expectEqual(@as(usize, 1), s.speakers[2].said);
}

test "a terminal that has closed still counts as having been here" {
    const alloc = testing.allocator;
    const members = [_]Member{.{ .id = "0x1111", .title = "W1" }};
    const events = [_]Event{
        .{ .seq = 1, .at_ms = hour, .op = "assigned", .task = 1, .title = "a", .owner = "0x9999", .state = "open", .progress = "queued" },
        .{ .seq = 2, .at_ms = hour, .op = "assigned", .task = 1, .title = "a", .owner = nobody, .state = "open", .progress = "queued" },
    };

    var s = try compute(alloc, .{
        .now_ms = 2 * hour,
        .stale_ms = 1,
        .events = &events,
        .tasks = &.{},
        .messages = &.{},
        .members = &members,
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    // W1 and the closed 0x9999. `nobody` is not a terminal.
    try testing.expectEqual(@as(usize, 1), s.terminals.now);
    try testing.expectEqual(@as(usize, 2), s.terminals.ever);
}

test "an empty group computes to zeroes rather than to nothing" {
    const alloc = testing.allocator;
    var s = try compute(alloc, .{
        .now_ms = hour,
        .stale_ms = 1,
        .events = &.{},
        .tasks = &.{},
        .messages = &.{},
        .members = &.{},
        .hour_of = testHour,
    });
    defer s.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), s.waiting.len);
    try testing.expectEqual(@as(usize, 0), s.session.messages);
    try testing.expectEqual(@as(usize, 0), s.life.counted);
    try testing.expectEqual(@as(u64, 0), s.silence.since_last_ms);
    try testing.expectEqual(@as(usize, 0), s.terminals.ever);
}
