//! The task page's answer (task 2015 Q4, `polter-artifacts/2015/API.md`
//! §2.2): one group's tasks as the page draws them -- the table, the open
//! one's story and what the group said about it, the closed ones folded,
//! the keys at the foot -- every word written in the person's language
//! and every row in the order to draw it.
//!
//! Pure: the panel, its record and the group's messages in, the JSON out.
//! The app gathers (`App.controlPage`), the same panel and record
//! `task_list` and `task_history` read; this only says.
//!
//! **Who did what is read off the operation**, because the record does not
//! keep who wrote a line: making, giving, closing and cancelling a task are
//! the supervisor's acts, and a change of progress is its owner's. A
//! person who closed a task by hand from the panel is written as the
//! supervisor -- the record cannot tell them apart.

const TaskPage = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tasks = @import("Tasks.zig");
const TaskLog = @import("TaskLog.zig");
const judge = @import("judge.zig");
const fill = @import("ControlRoom.zig").Say.fill;
const i18n = @import("../os/i18n.zig");

const Tr = judge.Tr;

/// A quiet spell in a task's story longer than this is drawn as a line of
/// its own.
pub const gap_ms: i64 = 10 * 60 * 1000;
/// How far back the group's messages are looked through for `#N`.
pub const said_ms: i64 = 7 * 24 * 3600 * 1000;
/// The most messages shown for one task, the newest.
pub const said_max = 20;

pub const Glyph = enum { queued, working, blocked, done, closed, cancelled };

pub const Task = struct {
    id: u64,
    title: []const u8,
    state: Tasks.State,
    progress: Tasks.Progress,
    /// What its owner is called; empty for nobody.
    owner: []const u8,
};

pub const Event = struct {
    at_ms: i64,
    op: TaskLog.Op,
    task: u64,
    progress: Tasks.Progress,
    /// The owner as of this line, by name; empty for nobody.
    owner: []const u8,
};

pub const Said = struct {
    at_ms: i64,
    who: []const u8,
    text: []const u8,
};

pub const In = struct {
    group: []const u8,
    goal: []const u8,
    /// Every task of the group, any order.
    tasks: []const Task,
    /// The group's record, oldest first (`TaskLog.history`).
    events: []const Event,
    /// The one shown open, if any, and what the group said of it -- already
    /// only the messages that name it (`mentions`), oldest first.
    open_task: ?u64,
    said: []const Said,
    closed: bool,
    now_ms: i64,
    offset_ms: i64,
    tr: Tr,
};

pub const words = struct {
    pub const head_id = i18n.N_("No.");
    pub const head_state = i18n.N_("State");
    pub const head_title = i18n.N_("Title");
    pub const head_owner = i18n.N_("Owner");
    pub const head_idle = i18n.N_("Quiet for");
    pub const queued = i18n.N_("Queued");
    pub const working = i18n.N_("In progress");
    pub const blocked = i18n.N_("Stuck");
    pub const done = i18n.N_("Done, to close");
    pub const closed = i18n.N_("Closed");
    pub const cancelled = i18n.N_("Cancelled");
    pub const nobody = i18n.N_("Nobody yet");
    pub const just_now = i18n.N_("Just now");
    pub const minutes = i18n.N_("{1} min");
    pub const hours = i18n.N_("{1} h");
    pub const yesterday = i18n.N_("Yesterday");
    pub const days = i18n.N_("{1} days ago");
    pub const body_title = i18n.N_("The task");
    pub const log_title = i18n.N_("What happened");
    pub const said_title = i18n.N_("What the group said about #{1}");
    pub const supervisor = i18n.N_("Supervisor");
    pub const op_created = i18n.N_("Made this task");
    pub const op_assigned = i18n.N_("Gave it to {1}");
    pub const op_unassigned = i18n.N_("Took it back");
    pub const op_working = i18n.N_("Started");
    pub const op_blocked = i18n.N_("Said it is stuck");
    pub const op_done = i18n.N_("Said it is done");
    pub const op_queued = i18n.N_("Put it back in the queue");
    pub const op_closed = i18n.N_("Closed it");
    pub const op_cancelled = i18n.N_("Cancelled it");
    pub const op_edited = i18n.N_("Changed its title");
    pub const op_compacted = i18n.N_("(What came before was merged)");
    pub const gap = i18n.N_("{1} min later");
    pub const closed_title = i18n.N_("{1} closed");
    pub const hint_pick = i18n.N_("Pick a task");
    pub const hint_fold = i18n.N_("Fold its story");
    pub const hint_open = i18n.N_("Open its story");
    pub const hint_filter = i18n.N_("Filter");
    pub const hint_only_open = i18n.N_("Open ones only");
    pub const hint_with_closed = i18n.N_("Closed ones too");

    pub const all = [_][:0]const u8{
        head_id,    head_state,   head_title,  head_owner,     head_idle,
        queued,     working,      blocked,     done,           closed,
        cancelled,  nobody,       just_now,    minutes,        hours,
        yesterday,  days,         body_title,  log_title,      said_title,
        supervisor, op_created,   op_assigned, op_unassigned,  op_working,
        op_blocked, op_done,      op_queued,   op_closed,      op_cancelled,
        op_edited,  op_compacted, gap,         closed_title,   hint_pick,
        hint_fold,  hint_open,    hint_filter, hint_only_open, hint_with_closed,
    };
};

// ------------------------------------------------------------- the shape

const Row = struct {
    id: u64,
    glyph: Glyph,
    state: []const u8,
    title: []const u8,
    owner: []const u8,
    idle: []const u8,
    emph: bool,
    detail: ?Detail = null,
};

const Detail = struct {
    body_title: []const u8,
    body: []const u8,
    log_title: []const u8,
    log: []const LogLine,
    said_title: []const u8,
    said: []const SaidOut,
};

const LogLine = struct {
    /// "event" or "gap". Not `kind`, which the hosts' gate reads as a
    /// host comparing kinds (API.md, seq 176).
    entry: []const u8,
    at: ?[]const u8 = null,
    who: ?[]const u8 = null,
    text: []const u8,
    last: bool = false,
};

const SaidOut = struct { at: []const u8, who: []const u8, text: []const u8 };

const Out = struct {
    page: []const u8 = "tasks",
    group: []const u8,
    goal: []const u8,
    head: struct { id: []const u8, state: []const u8, title: []const u8, owner: []const u8, idle: []const u8 },
    open: []const Row,
    closed_title: []const u8,
    closed_count: usize,
    closed: []const Row,
    hints: []const struct { key: []const u8, text: []const u8 },
};

// ------------------------------------------------------------ the saying

pub fn render(arena: Allocator, in: In) Allocator.Error![]u8 {
    const tr = in.tr;
    var open: std.ArrayListUnmanaged(Row) = .empty;
    var closed: std.ArrayListUnmanaged(Row) = .empty;
    var closed_count: usize = 0;

    const sorted = try arena.dupe(Task, in.tasks);
    std.mem.sort(Task, sorted, {}, struct {
        fn lt(_: void, a: Task, b: Task) bool {
            return a.id < b.id;
        }
    }.lt);

    for (sorted) |t| {
        const shut = t.state != .open;
        if (shut) closed_count += 1;
        if (shut and !in.closed) continue;
        var row: Row = .{
            .id = t.id,
            .glyph = glyphOf(t),
            .state = tr(stateWord(t)),
            .title = t.title,
            .owner = if (t.owner.len > 0) t.owner else tr(words.nobody),
            .idle = try idle(arena, tr, lastAt(in.events, t.id), in.now_ms, in.offset_ms),
            .emph = in.open_task == t.id,
        };
        if (in.open_task == t.id) row.detail = try detail(arena, in, t);
        try (if (shut) &closed else &open).append(arena, row);
    }
    // The newest closed first: what was just finished is what is looked for.
    std.mem.reverse(Row, closed.items);

    const Hint = @typeInfo(@FieldType(Out, "hints")).pointer.child;
    const out: Out = .{
        .group = in.group,
        .goal = in.goal,
        .head = .{ .id = tr(words.head_id), .state = tr(words.head_state), .title = tr(words.head_title), .owner = tr(words.head_owner), .idle = tr(words.head_idle) },
        .open = open.items,
        .closed_title = try fill(arena, tr(words.closed_title), &.{try num(arena, closed_count)}),
        .closed_count = closed_count,
        .closed = closed.items,
        .hints = try arena.dupe(Hint, &.{
            .{ .key = "↑↓", .text = tr(words.hint_pick) },
            .{ .key = "Enter", .text = tr(if (in.open_task != null) words.hint_fold else words.hint_open) },
            .{ .key = "f", .text = tr(words.hint_filter) },
            .{ .key = "c", .text = tr(if (in.closed) words.hint_only_open else words.hint_with_closed) },
        }),
    };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

fn glyphOf(t: Task) Glyph {
    return switch (t.state) {
        .closed => .closed,
        .cancelled => .cancelled,
        .open => switch (t.progress) {
            .queued => .queued,
            .working => .working,
            .blocked => .blocked,
            .done => .done,
        },
    };
}

fn stateWord(t: Task) [:0]const u8 {
    return switch (glyphOf(t)) {
        .queued => words.queued,
        .working => words.working,
        .blocked => words.blocked,
        .done => words.done,
        .closed => words.closed,
        .cancelled => words.cancelled,
    };
}

fn lastAt(events: []const Event, id: u64) ?i64 {
    var at: ?i64 = null;
    for (events) |e| if (e.task == id) {
        at = if (at) |a| @max(a, e.at_ms) else e.at_ms;
    };
    return at;
}

/// "2 min", "1 h", "Yesterday", "3 days ago"; "—" with nothing in the
/// record (older than it reaches).
fn idle(arena: Allocator, tr: Tr, at: ?i64, now_ms: i64, offset_ms: i64) Allocator.Error![]const u8 {
    const a = at orelse return "—";
    const d = @max(0, now_ms - a);
    const min: i64 = 60_000;
    if (d < min) return tr(words.just_now);
    if (d < 60 * min) return fill(arena, tr(words.minutes), &.{try num(arena, @divFloor(d, min))});
    const day: i64 = 24 * 60 * min;
    const today = @divFloor(now_ms + offset_ms, day);
    const then = @divFloor(a + offset_ms, day);
    if (today == then) return fill(arena, tr(words.hours), &.{try num(arena, @divFloor(d, 60 * min))});
    if (today - then == 1) return tr(words.yesterday);
    return fill(arena, tr(words.days), &.{try num(arena, today - then)});
}

fn detail(arena: Allocator, in: In, t: Task) Allocator.Error!Detail {
    const tr = in.tr;
    var log: std.ArrayListUnmanaged(LogLine) = .empty;
    var prev: ?i64 = null;
    for (in.events) |e| {
        if (e.task != t.id) continue;
        if (prev) |p| if (e.at_ms - p > gap_ms) {
            try log.append(arena, .{ .entry = "gap", .text = try fill(arena, tr(words.gap), &.{try num(arena, @divFloor(e.at_ms - p, 60_000))}) });
        };
        prev = e.at_ms;
        const by_owner = e.op == .progressed;
        try log.append(arena, .{
            .entry = "event",
            .at = try clock(arena, e.at_ms, in.offset_ms),
            .who = if (e.op == .compacted) null else if (by_owner) (if (e.owner.len > 0) e.owner else tr(words.nobody)) else tr(words.supervisor),
            .text = try opText(arena, tr, e),
        });
    }
    // The last line is the latest word.
    var i = log.items.len;
    while (i > 0) : (i -= 1) if (std.mem.eql(u8, log.items[i - 1].entry, "event")) {
        log.items[i - 1].last = true;
        break;
    };

    const said = in.said[in.said.len -| said_max..];
    const out = try arena.alloc(SaidOut, said.len);
    for (said, out) |s, *o| o.* = .{ .at = try clock(arena, s.at_ms, in.offset_ms), .who = s.who, .text = s.text };

    var idn: [24]u8 = undefined;
    return .{
        .body_title = tr(words.body_title),
        // The task's own words: the first message that named it, which is
        // the supervisor handing it out; else its one-line title.
        .body = if (in.said.len > 0) in.said[0].text else t.title,
        .log_title = tr(words.log_title),
        .log = log.items,
        .said_title = try fill(arena, tr(words.said_title), &.{std.fmt.bufPrint(&idn, "{d}", .{t.id}) catch ""}),
        .said = out,
    };
}

fn opText(arena: Allocator, tr: Tr, e: Event) Allocator.Error![]const u8 {
    return switch (e.op) {
        .created => tr(words.op_created),
        .assigned => if (e.owner.len > 0) try fill(arena, tr(words.op_assigned), &.{e.owner}) else tr(words.op_unassigned),
        .progressed => tr(switch (e.progress) {
            .working => words.op_working,
            .blocked => words.op_blocked,
            .done => words.op_done,
            .queued => words.op_queued,
        }),
        .closed => tr(words.op_closed),
        .cancelled => tr(words.op_cancelled),
        .edited => tr(words.op_edited),
        .compacted => tr(words.op_compacted),
    };
}

/// Whether `text` names task `id` as `#id`, and not as the start of a
/// longer number (#21 is not in "#215").
pub fn mentions(text: []const u8, id: u64) bool {
    var buf: [24]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "#{d}", .{id}) catch return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, tag)) |at| {
        const after = at + tag.len;
        if (after >= text.len or !std.ascii.isDigit(text[after])) return true;
        from = at + 1;
    }
    return false;
}

fn num(arena: Allocator, n: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn clock(arena: Allocator, at_ms: i64, offset_ms: i64) Allocator.Error![]const u8 {
    const day_ms: i64 = 24 * 3600 * 1000;
    const mins: u64 = @intCast(@divFloor(@mod(at_ms + offset_ms, day_ms), 60_000));
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ mins / 60, mins % 60 });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
/// 2026-10-21 12:00 UTC: 20:00 at UTC+8.
const noon: i64 = 1792584000000;
const plus8: i64 = 8 * 3600 * 1000;
const minute: i64 = 60_000;

const Got = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,

    fn deinit(self: *Got) void {
        self.arena.deinit();
    }
};

fn rendered(in: In) !Got {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    const json = try render(arena.allocator(), in);
    // Parsed before the arena is copied out, or the copy misses what the
    // parse took.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    return .{ .arena = arena, .root = root };
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

const sample_tasks = [_]Task{
    .{ .id = 215, .title = "PATCH /api/tasks takes a list of ids", .state = .open, .progress = .working, .owner = "api" },
    .{ .id = 214, .title = "Multi-select", .state = .open, .progress = .done, .owner = "frontend" },
    .{ .id = 218, .title = "Optimistic or refetch?", .state = .open, .progress = .queued, .owner = "" },
    .{ .id = 213, .title = "List and filter", .state = .closed, .progress = .done, .owner = "api" },
    .{ .id = 212, .title = "Shell and routes", .state = .closed, .progress = .done, .owner = "frontend" },
    .{ .id = 211, .title = "Dropped", .state = .cancelled, .progress = .queued, .owner = "" },
};

/// #215's story: made, given, started; 18 minutes of nothing; stuck,
/// answered, going again. #214 last moved 17 minutes before now.
const sample_events = [_]Event{
    .{ .at_ms = noon - 35 * minute, .op = .created, .task = 215, .progress = .queued, .owner = "" },
    .{ .at_ms = noon - 35 * minute, .op = .assigned, .task = 215, .progress = .queued, .owner = "api" },
    .{ .at_ms = noon - 34 * minute, .op = .progressed, .task = 215, .progress = .working, .owner = "api" },
    .{ .at_ms = noon - 17 * minute, .op = .progressed, .task = 214, .progress = .done, .owner = "frontend" },
    .{ .at_ms = noon - 16 * minute, .op = .progressed, .task = 215, .progress = .blocked, .owner = "api" },
    .{ .at_ms = noon - 13 * minute, .op = .progressed, .task = 215, .progress = .working, .owner = "api" },
    .{ .at_ms = noon - 2 * minute, .op = .edited, .task = 215, .progress = .working, .owner = "api" },
};

const sample_said = [_]Said{
    .{ .at_ms = noon - 35 * minute, .who = "Supervisor", .text = "#215 to api: PATCH /api/tasks takes a list of ids, all or nothing." },
    .{ .at_ms = noon - 16 * minute, .who = "api", .text = "#215 stuck: one id is closed already." },
};

fn baseIn() In {
    return .{
        .group = "web-app",
        .goal = "Bulk editing for the task list.",
        .tasks = &sample_tasks,
        .events = &sample_events,
        .open_task = null,
        .said = &.{},
        .closed = false,
        .now_ms = noon,
        .offset_ms = plus8,
        .tr = judge.english,
    };
}

test "2015: the open tasks in number order, each with its state, owner and how long it has been quiet" {
    var got = try rendered(baseIn());
    defer got.deinit();
    const open = got.root.object.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 3), open.len);
    try testing.expectEqual(@as(i64, 214), open[0].object.get("id").?.integer);
    try testing.expectEqualStrings("done", str(open[0], "glyph"));
    try testing.expectEqualStrings("Done, to close", str(open[0], "state"));
    try testing.expectEqualStrings("17 min", str(open[0], "idle"));
    try testing.expectEqualStrings("working", str(open[1], "glyph"));
    try testing.expectEqualStrings("2 min", str(open[1], "idle"));
    // Nobody has it, and the record never mentions it.
    try testing.expectEqualStrings("Nobody yet", str(open[2], "owner"));
    try testing.expectEqualStrings("—", str(open[2], "idle"));
    // Closed and cancelled are counted, not listed, until asked for.
    try testing.expectEqual(@as(i64, 3), got.root.object.get("closed_count").?.integer);
    try testing.expectEqualStrings("3 closed", str(got.root, "closed_title"));
    try testing.expectEqual(@as(usize, 0), got.root.object.get("closed").?.array.items.len);
    try testing.expectEqualStrings("Bulk editing for the task list.", str(got.root, "goal"));
    try testing.expectEqualStrings("Open its story", str(got.root.object.get("hints").?.array.items[1], "text"));
}

test "2015: the open task's story says who did what, marks the long quiet, and ends on the latest" {
    var in = baseIn();
    in.open_task = 215;
    in.said = &sample_said;
    var got = try rendered(in);
    defer got.deinit();
    const row = got.root.object.get("open").?.array.items[1];
    try testing.expect(row.object.get("emph").?.bool);
    const d = row.object.get("detail").?;
    // The task's words are the message that handed it out.
    try testing.expectEqualStrings(sample_said[0].text, str(d, "body"));
    try testing.expectEqualStrings("What the group said about #215", str(d, "said_title"));
    const log = d.object.get("log").?.array.items;
    try testing.expectEqualStrings("19:25", str(log[0], "at"));
    try testing.expectEqualStrings("Supervisor", str(log[0], "who"));
    try testing.expectEqualStrings("Made this task", str(log[0], "text"));
    try testing.expectEqualStrings("Gave it to api", str(log[1], "text"));
    try testing.expectEqualStrings("api", str(log[2], "who"));
    try testing.expectEqualStrings("Started", str(log[2], "text"));
    // 34 to 16 minutes before: eighteen minutes of nothing.
    try testing.expectEqualStrings("gap", str(log[3], "entry"));
    try testing.expectEqualStrings("18 min later", str(log[3], "text"));
    try testing.expectEqualStrings("Said it is stuck", str(log[4], "text"));
    try testing.expectEqualStrings("gap", str(log[6], "entry"));
    try testing.expectEqualStrings("Changed its title", str(log[7], "text"));
    try testing.expect(log[7].object.get("last").?.bool);
    try testing.expect(!log[2].object.get("last").?.bool);
    try testing.expectEqual(@as(usize, 2), d.object.get("said").?.array.items.len);
    try testing.expectEqualStrings("Fold its story", str(got.root.object.get("hints").?.array.items[1], "text"));
}

test "2015: the closed ones, asked for, come newest first" {
    var in = baseIn();
    in.closed = true;
    var got = try rendered(in);
    defer got.deinit();
    const closed = got.root.object.get("closed").?.array.items;
    try testing.expectEqual(@as(usize, 3), closed.len);
    try testing.expectEqual(@as(i64, 213), closed[0].object.get("id").?.integer);
    try testing.expectEqualStrings("closed", str(closed[0], "glyph"));
    try testing.expectEqualStrings("cancelled", str(closed[2], "glyph"));
    try testing.expectEqualStrings("Open ones only", str(got.root.object.get("hints").?.array.items[3], "text"));
}

test "2015: #21 is not in #215, and #215 is in #215, and in #215's end" {
    try testing.expect(mentions("task #215 → api", 215));
    try testing.expect(mentions("done: #215", 215));
    try testing.expect(mentions("#215.", 215));
    try testing.expect(!mentions("task #215 → api", 21));
    try testing.expect(!mentions("#2150 is another", 215));
    try testing.expect(mentions("#2150 and then #215", 215));
    try testing.expect(!mentions("215 without its mark", 215));
}

test "2015: quiet for minutes, hours, yesterday, days" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = judge.english;
    try testing.expectEqualStrings("Just now", try idle(a, tr, noon - 30_000, noon, plus8));
    try testing.expectEqualStrings("59 min", try idle(a, tr, noon - 59 * minute, noon, plus8));
    // 20:00 local: three hours ago is still today.
    try testing.expectEqualStrings("3 h", try idle(a, tr, noon - 180 * minute, noon, plus8));
    try testing.expectEqualStrings("Yesterday", try idle(a, tr, noon - 21 * 60 * minute, noon, plus8));
    try testing.expectEqualStrings("3 days ago", try idle(a, tr, noon - 3 * 24 * 60 * minute, noon, plus8));
}

test "2015: every sentence of the task page is in po/zh_CN.po" {
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
        const said_ = found orelse {
            std.debug.print("not in po/zh_CN.po: {s}\n", .{msgid});
            return error.Untranslated;
        };
        try testing.expect(said_.len > 0);
    }
}
