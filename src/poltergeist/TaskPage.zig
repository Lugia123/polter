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

pub const TaskMember = struct {
    alias: []const u8,
    role: []const u8,
    lead: bool = false,
    /// `filled`, `empty` or `vacated` -- a machine token, and the whole of
    /// what the page knows about the seat. The host says the word.
    slot: []const u8 = "filled",
    terminal: []const u8 = "—",
    cli: []const u8 = "",
};

pub const SquadDetail = struct {
    /// The template's name as a person reads it, resolved by
    /// `App.renderTasks`; the key when no template of that key is on this
    /// machine any more, so a task whose squad was deleted still says what
    /// it was. `Task.squad` is the key.
    name: []const u8,
    seats: []const TaskMember,
};

pub const WorktreeDetail = struct {
    /// `wt/<group>/<task>`, from the same rule the tree was named by.
    branch: []const u8,
    /// Where it is, from the worktree ledger. Empty for a tree that is
    /// planned and not made yet: nothing has been created to point at.
    path: []const u8,
    /// `made` or `planned` -- a token, not a sentence. There is no word in
    /// the core's tables for "planned", and both hosts have one.
    state: []const u8,
};

pub const TokenSlice = struct {
    alias: []const u8,
    role: []const u8,
    tokens: []const u8,
    pct: u8,
    color: []const u8,
};

pub const TokensDetail = struct {
    total: []const u8,
    breakdown: []const TokenSlice,
};

pub const Task = struct {
    id: u64,
    title: []const u8,
    state: Tasks.State,
    progress: Tasks.Progress,
    /// What its owner is called; empty for nobody.
    owner: []const u8,
    /// The squad template's **key** this task's seats came from
    /// (`Tasks.Task.squad`); "" for a task with no squad. The key is what
    /// the panel stores and what a record replays.
    squad: []const u8 = "",
    /// What that template is called, looked up by the app -- the only thing
    /// that holds the template table. Falls back to the key when no
    /// template of that key is on the machine any more, so a task whose
    /// squad was deleted still says which one it was.
    squad_name: []const u8 = "",
    /// Whether the task has a tree, and which kind: `made` or `planned`;
    /// "" for a task that uses none, and for one from before the question
    /// existed (`unset`). A token -- the host says the word.
    worktree: []const u8 = "",
    /// Where the tree is, from the worktree ledger (`Ledger.Entry.path`).
    /// Empty for a tree that is only planned: nothing is on disk yet.
    worktree_path: []const u8 = "",
    /// Squad seats if this task has a squad.
    members: []const TaskMember = &.{},
    /// Token stats if available.
    tokens: ?TokensDetail = null,
};

pub const Event = struct {
    at_ms: i64,
    op: TaskLog.Op,
    task: u64,
    progress: Tasks.Progress,
    /// The owner as of this line, by name; empty for nobody.
    owner: []const u8,
    /// For `reowned`: `<cli> <session>` it went by (task 1978).
    via: []const u8 = "",
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
    /// The one the arrow keys are on (task 2083), for what Enter says it
    /// will do to it: fold when it is the open one, open it when not. Null
    /// from a host that does not say: Enter then says fold while any is
    /// open, as before.
    selected: ?u64 = null,
    said: []const Said,
    closed: bool,
    /// What the filter box holds (task 2083): null with no box, "" with
    /// one just opened. A title is matched here, ASCII case ignored, and so
    /// is the task's number as the page draws it (task 2248, `matches`) --
    /// so the page's every word -- the count, the "nothing has it" -- is
    /// written where the matching is done.
    filter: ?[]const u8 = null,
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
    pub const op_reowned = i18n.N_("Back after a restart, the same session ({1})");
    pub const gap = i18n.N_("{1} min later");
    pub const hint_pick = i18n.N_("Pick a task");
    pub const hint_fold = i18n.N_("Fold its story");
    pub const hint_open = i18n.N_("Open its story");
    // The closed ones' row and the c key's word on it (task 2083,
    // `polter-artifacts/2083/v1`): hidden by default, and said to be.
    pub const closed_hidden = i18n.N_("{1} closed or cancelled tasks hidden");
    pub const closed_shown = i18n.N_("{1} closed or cancelled");
    pub const closed_matched = i18n.N_("{1} more closed with \"{2}\" in the title");
    pub const closed_show_row = i18n.N_("or click this row to show them");
    pub const closed_hide_row = i18n.N_("Hide");
    pub const hint_show_closed = i18n.N_("Show the {1} closed");
    pub const hint_hide_closed = i18n.N_("Hide the closed");
    // The filter: f opens it, Esc clears it (task 2083).
    pub const hint_filter = i18n.N_("Filter by title");
    pub const hint_pick_match = i18n.N_("Pick among the results");
    pub const hint_clear = i18n.N_("Clear the filter");
    pub const filter_count = i18n.N_("{1} / {2}");
    pub const filter_clear = i18n.N_("Clear filter");
    pub const no_match = i18n.N_("No task has \"{1}\" in its title");
    // Each a whole sentence pair, so that a language puts the space between
    // them, or none, as it does.
    pub const no_match_closed = i18n.N_("{1} closed ones have \"{2}\" in the title; press c to show them. Press Esc to clear the filter.");
    pub const no_match_searched = i18n.N_("The closed ones were searched too. Press Esc to clear the filter.");

    pub const all = [_][:0]const u8{
        head_id,         head_state,        head_title,       head_owner,       head_idle,
        queued,          working,           blocked,          done,             closed,
        cancelled,       nobody,            just_now,         minutes,          hours,
        yesterday,       days,              body_title,       log_title,        said_title,
        supervisor,      op_created,        op_assigned,      op_unassigned,    op_working,
        op_blocked,      op_done,           op_queued,        op_closed,        op_cancelled,
        op_edited,       op_compacted,      gap,              hint_pick,        hint_fold,
        hint_open,       op_reowned,        closed_hidden,    closed_shown,     closed_matched,
        closed_show_row, closed_hide_row,   hint_show_closed, hint_hide_closed, hint_filter,
        hint_pick_match, hint_clear,        filter_count,     filter_clear,     no_match,
        no_match_closed, no_match_searched,
    };
};

// ------------------------------------------------------------- the shape

const Row = struct {
    id: u64,
    glyph: Glyph,
    state: []const u8,
    title: []const u8,
    /// With a filter (task 2083): `title` cut where the filter is in it,
    /// for the host to draw the `hit` pieces marked. Null with no filter,
    /// or an empty one: the host draws `title`. Cut here rather than given
    /// as offsets, because the two hosts count a string in different units
    /// and the rule for what matches is in one place, this one.
    title_parts: ?[]const Part = null,
    owner: []const u8,
    idle: []const u8,
    emph: bool,
    detail: ?Detail = null,
    worktree: ?[]const u8 = null,
};

const Part = struct { text: []const u8, hit: bool };

const Detail = struct {
    body_title: []const u8,
    body: []const u8,
    log_title: []const u8,
    log: []const LogLine,
    said_title: []const u8,
    said: []const SaidOut,
    squad: ?SquadDetail = null,
    worktree: ?WorktreeDetail = null,
    tokens: ?TokensDetail = null,
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
    /// `goal` a line to an item (task 2060): split at its newlines, the
    /// empty ones left out. A host draws these as the rows under the
    /// group's name and wraps each to its own width, as the chat's brief
    /// does (`briefRows`, task 2043). `goal` drawn on one line ran the
    /// lines together -- "…工具条- api: …".
    goal_lines: []const []const u8,
    head: struct { id: []const u8, state: []const u8, title: []const u8, owner: []const u8, idle: []const u8 },
    open: []const Row,
    /// The closed ones' row: what it says, and the key beside it. Null
    /// when there is no row -- nothing closed, or nothing closed matching.
    closed_title: ?[]const u8,
    closed_key: ?Hint,
    /// The closed ones the row stands for: all of them, or with a filter
    /// the ones matching it.
    closed_count: usize,
    closed: []const Row,
    /// The keys along the bottom, left to right, and the c key's at its
    /// right end -- null when nothing is closed.
    hints: []const Hint,
    hint_closed: ?Hint,
    filter: ?Filter,
    /// No open task matches a filter: what to say instead of the list.
    no_match: ?NoMatch,
};

const Hint = struct { key: []const u8, text: []const u8 };

const Filter = struct {
    /// The grey words in an empty box.
    prompt: []const u8,
    /// What the box holds, as given.
    text: []const u8,
    /// "4 / 9": matching open tasks of all the open ones; null while the
    /// box is empty.
    count: ?[]const u8,
    clear: Hint,
};

const NoMatch = struct { title: []const u8, detail: []const u8 };

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

    const q = in.filter orelse "";
    var open_count: usize = 0;
    for (sorted) |t| {
        const shut = t.state != .open;
        if (!shut) open_count += 1;
        if (!matches(t, q)) continue;
        if (shut) closed_count += 1;
        if (shut and !in.closed) continue;
        var row: Row = .{
            .id = t.id,
            .glyph = glyphOf(t),
            .state = tr(stateWord(t)),
            .title = t.title,
            // **The squad's name, not its key**: the key is `wt-polter`, the
            // name is what the person made the template to be called. The
            // key is the fallback, for a squad whose template is gone.
            .owner = if (t.squad_name.len > 0)
                t.squad_name
            else if (t.squad.len > 0)
                t.squad
            else if (t.owner.len > 0)
                t.owner
            else
                tr(words.nobody),
            .idle = try idle(arena, tr, lastAt(in.events, t.id), in.now_ms, in.offset_ms),
            .emph = in.open_task == t.id,
            .worktree = if (t.worktree.len > 0) try branchOf(arena, in.group, t.id) else null,
        };
        if (q.len > 0) row.title_parts = try titleParts(arena, t.title, q);
        if (in.open_task == t.id) row.detail = try detail(arena, in, t);
        try (if (shut) &closed else &open).append(arena, row);
    }
    // The newest closed first: what was just finished is what is looked for.
    std.mem.reverse(Row, closed.items);

    const n_closed = try num(arena, closed_count);
    const filtering = q.len > 0;
    // The row is there when it stands for something; with a filter, only
    // when some closed ones match it -- and not when no open one does,
    // where `no_match` says it instead (2083/v1, 04-filter).
    const row_title: ?[]const u8 = if (closed_count == 0 or (filtering and open.items.len == 0))
        null
    else if (in.closed)
        try fill(arena, tr(words.closed_shown), &.{n_closed})
    else if (filtering)
        try fill(arena, tr(words.closed_matched), &.{ n_closed, q })
    else
        try fill(arena, tr(words.closed_hidden), &.{n_closed});
    const all_closed = sorted.len - open_count;
    const hint_closed: ?Hint = if (all_closed == 0) null else .{
        .key = "c",
        .text = if (in.closed) tr(words.hint_hide_closed) else try fill(arena, tr(words.hint_show_closed), &.{try num(arena, all_closed)}),
    };
    // What Enter does to the selected one (round 6, F5: with #308 selected
    // and #306 open, it said "fold this one").
    const folds = if (in.open_task) |id| (in.selected orelse id) == id else false;
    const enter: Hint = .{ .key = "Enter", .text = tr(if (folds) words.hint_fold else words.hint_open) };
    const hints: []const Hint = if (in.filter != null)
        try arena.dupe(Hint, &.{ .{ .key = "↑↓", .text = tr(words.hint_pick_match) }, enter, .{ .key = "Esc", .text = tr(words.hint_clear) } })
    else
        try arena.dupe(Hint, &.{ .{ .key = "↑↓", .text = tr(words.hint_pick) }, enter, .{ .key = "f", .text = tr(words.hint_filter) } });

    const out: Out = .{
        .group = in.group,
        .goal = in.goal,
        .goal_lines = try goalLines(arena, in.goal),
        .head = .{ .id = tr(words.head_id), .state = tr(words.head_state), .title = tr(words.head_title), .owner = tr(words.head_owner), .idle = tr(words.head_idle) },
        .open = open.items,
        .closed_title = row_title,
        .closed_key = if (row_title == null) null else .{
            .key = "c",
            .text = tr(if (in.closed) words.closed_hide_row else words.closed_show_row),
        },
        .closed_count = closed_count,
        .closed = closed.items,
        .hints = hints,
        .hint_closed = hint_closed,
        .filter = if (in.filter == null) null else .{
            .prompt = tr(words.hint_filter),
            .text = q,
            .count = if (filtering) try fill(arena, tr(words.filter_count), &.{ try num(arena, open.items.len), try num(arena, open_count) }) else null,
            .clear = .{ .key = "Esc", .text = tr(words.filter_clear) },
        },
        .no_match = if (!filtering or open.items.len > 0) null else .{
            .title = try fill(arena, tr(words.no_match), &.{q}),
            .detail = if (closed_count > 0 and !in.closed)
                try fill(arena, tr(words.no_match_closed), &.{ n_closed, q })
            else
                tr(words.no_match_searched),
        },
    };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

/// The goal's lines: split at LF and CRLF, each trimmed at its ends, the
/// empty ones left out.
fn goalLines(arena: Allocator, goal: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitAny(u8, goal, "\r\n");
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 0) try out.append(arena, t);
    }
    return out.items;
}

/// `title` in pieces, each `q` in it a `hit`, ASCII case ignored; every
/// piece is whole characters, because a valid `q` found in valid UTF-8 can
/// only start and end where characters do.
fn titleParts(arena: Allocator, title: []const u8, q: []const u8) Allocator.Error![]const Part {
    var out: std.ArrayListUnmanaged(Part) = .empty;
    var at: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(title, at, q)) |hit| {
        if (hit > at) try out.append(arena, .{ .text = title[at..hit], .hit = false });
        try out.append(arena, .{ .text = title[hit .. hit + q.len], .hit = true });
        at = hit + q.len;
    }
    if (at < title.len) try out.append(arena, .{ .text = title[at..], .hit = false });
    return out.items;
}

/// Whether `q` finds this task: **its number**, written the way the page
/// draws it in the first column (`2149`, or `#2149`), or a piece of its
/// title, ASCII case ignored. An empty `q` finds every task.
///
/// Task 2248: a person read a number off the page's own first column, typed
/// it in the box, and was told nothing had it -- the number was the one
/// thing the page shows that the filter never looked at.
fn matches(t: Task, q: []const u8) bool {
    if (q.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(t.title, q) != null) return true;
    return numberIs(t.id, q);
}

/// Whether `q` is `id`'s number: the digits, with or without the `#` the
/// page draws in front of them.
///
/// **The digits as written, not a parsed value.** Nothing becomes an integer,
/// so nothing can overflow and nothing is trimmed: `214` is neither #2149 nor
/// #21490, and `02149` is not #2149.
fn numberIs(id: u64, q: []const u8) bool {
    if (q.len == 0) return false;
    const digits = if (q[0] == '#') q[1..] else q;
    if (digits.len == 0) return false;
    var buf: [20]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return false;
    return std.mem.eql(u8, n, digits);
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
        const by_owner = e.op == .progressed or e.op == .reowned;
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

    var sq_detail: ?SquadDetail = null;
    if (t.members.len > 0) sq_detail = .{
        // The name, with the key as its fallback -- the same pair the row's
        // owner column reads (see `render`).
        .name = if (t.squad_name.len > 0) t.squad_name else t.squad,
        .seats = t.members,
    };

    var wt_detail: ?WorktreeDetail = null;
    if (t.worktree.len > 0) wt_detail = .{
        .branch = try branchOf(arena, in.group, t.id),
        .path = t.worktree_path,
        .state = t.worktree,
    };

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
        .squad = sq_detail,
        .worktree = wt_detail,
        .tokens = t.tokens,
    };
}

/// A task's tree's branch name: the row's tag and the detail's card say the
/// same thing because they come from here. `Worktree.taskBranch` names the
/// branch the tree is actually made on; this is that name, so a host that
/// draws it is not inventing one.
fn branchOf(arena: Allocator, group: []const u8, id: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "wt/{s}/{d}", .{ group, id });
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
        .reowned => try fill(arena, tr(words.op_reowned), &.{e.via}),
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

test "1978: a task taken up after a restart says so, by the one that has it, and by which session" {
    const events = sample_events ++ [_]Event{
        .{ .at_ms = noon - 1 * minute, .op = .reowned, .task = 215, .progress = .working, .owner = "api-2", .via = "claude-code 55a835df" },
    };
    var in = baseIn();
    in.open_task = 215;
    in.events = &events;
    var got = try rendered(in);
    defer got.deinit();
    const log = got.root.object.get("open").?.array.items[1].object.get("detail").?.object.get("log").?.array.items;
    const back = log[log.len - 1];
    try testing.expectEqualStrings("api-2", str(back, "who"));
    try testing.expectEqualStrings("Back after a restart, the same session (claude-code 55a835df)", str(back, "text"));
}

test "2083: Enter says it folds only the selected one when that one is open" {
    const enter = struct {
        fn said(in: In) ![]const u8 {
            var got = try rendered(in);
            defer got.deinit();
            const hint = got.root.object.get("hints").?.array.items[1];
            return testing.allocator.dupe(u8, str(hint, "text"));
        }
    };
    var in = baseIn();
    in.open_task = 215;
    // The open one selected: fold.
    in.selected = 215;
    const fold = try enter.said(in);
    defer testing.allocator.free(fold);
    try testing.expectEqualStrings(words.hint_fold, fold);
    // Another selected: open it.
    in.selected = 218;
    const other = try enter.said(in);
    defer testing.allocator.free(other);
    try testing.expectEqualStrings(words.hint_open, other);
    // Not said: as before, fold while one is open.
    in.selected = null;
    const unsaid = try enter.said(in);
    defer testing.allocator.free(unsaid);
    try testing.expectEqualStrings(words.hint_fold, unsaid);
    // None open: open.
    in.open_task = null;
    in.selected = 215;
    const none = try enter.said(in);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings(words.hint_open, none);
}

test "2060: a goal of several lines is handed over a line to an item, none of them joined, none empty" {
    var in = baseIn();
    // The brief the Windows page ran together as "…工具条- api: …".
    in.goal = "第 5 轮进行中（2026-10-22）：\r\n- frontend：列表多选和工具条\n\n- api: PATCH /api/tasks  \n";
    var got = try rendered(in);
    defer got.deinit();
    const lines = got.root.object.get("goal_lines").?.array.items;
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("第 5 轮进行中（2026-10-22）：", lines[0].string);
    try testing.expectEqualStrings("- frontend：列表多选和工具条", lines[1].string);
    try testing.expectEqualStrings("- api: PATCH /api/tasks", lines[2].string);
    // `goal` is still the brief as written, for a host that reads it.
    try testing.expectEqualStrings(in.goal, str(got.root, "goal"));

    // One line is one item; no brief is none.
    var one = try rendered(baseIn());
    defer one.deinit();
    const only = one.root.object.get("goal_lines").?.array.items;
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("Bulk editing for the task list.", only[0].string);
    in.goal = "";
    var none = try rendered(in);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.root.object.get("goal_lines").?.array.items.len);
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
    try testing.expectEqualStrings("3 closed or cancelled tasks hidden", str(got.root, "closed_title"));
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
    try testing.expectEqualStrings("3 closed or cancelled", str(got.root, "closed_title"));
    try testing.expectEqualStrings("Hide", str(got.root.object.get("closed_key").?, "text"));
    try testing.expectEqualStrings("Hide the closed", str(got.root.object.get("hint_closed").?, "text"));
}

test "2083: the closed ones are hidden by default and the page says so, on their row and at the end of the keys" {
    var got = try rendered(baseIn());
    defer got.deinit();
    const root = got.root;
    try testing.expectEqualStrings("3 closed or cancelled tasks hidden", str(root, "closed_title"));
    const row_key = root.object.get("closed_key").?;
    try testing.expectEqualStrings("c", str(row_key, "key"));
    try testing.expectEqualStrings("or click this row to show them", str(row_key, "text"));
    try testing.expectEqualStrings("Show the 3 closed", str(root.object.get("hint_closed").?, "text"));
    const hints = root.object.get("hints").?.array.items;
    try testing.expectEqual(@as(usize, 3), hints.len);
    try testing.expectEqualStrings("Pick a task", str(hints[0], "text"));
    try testing.expectEqualStrings("f", str(hints[2], "key"));
    try testing.expectEqualStrings("Filter by title", str(hints[2], "text"));
    try testing.expect(root.object.get("filter").? == .null);
    try testing.expect(root.object.get("no_match").? == .null);

    // Nothing closed: no row, and no c at the end of the keys.
    const only_open = [_]Task{sample_tasks[0]};
    var in = baseIn();
    in.tasks = &only_open;
    var none = try rendered(in);
    defer none.deinit();
    try testing.expect(none.root.object.get("closed_title").? == .null);
    try testing.expect(none.root.object.get("closed_key").? == .null);
    try testing.expect(none.root.object.get("hint_closed").? == .null);
}

test "2083: a filter keeps the titles that have it, case ignored, and the page counts and words it" {
    var in = baseIn();
    // Just opened: everything, the prompt, no count yet, Esc to leave.
    in.filter = "";
    var empty = try rendered(in);
    defer empty.deinit();
    const box = empty.root.object.get("filter").?;
    try testing.expectEqualStrings("Filter by title", str(box, "prompt"));
    try testing.expect(box.object.get("count").? == .null);
    try testing.expectEqualStrings("Esc", str(box.object.get("clear").?, "key"));
    try testing.expectEqual(@as(usize, 3), empty.root.object.get("open").?.array.items.len);
    // An empty box marks nothing: the host draws the titles as they are.
    try testing.expect(empty.root.object.get("open").?.array.items[0].object.get("title_parts").? == .null);
    const keys = empty.root.object.get("hints").?.array.items;
    try testing.expectEqualStrings("Pick among the results", str(keys[0], "text"));
    try testing.expectEqualStrings("Esc", str(keys[2], "key"));
    try testing.expectEqualStrings("Clear the filter", str(keys[2], "text"));

    // "LIST" is in #215's title and, among the closed, #213's.
    in.filter = "LIST";
    var got = try rendered(in);
    defer got.deinit();
    const open = got.root.object.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqual(@as(i64, 215), open[0].object.get("id").?.integer);
    // The title in pieces, the hit as the title has it, not as typed.
    const parts_v = open[0].object.get("title_parts").?;
    try testing.expect(parts_v != .null);
    const parts = parts_v.array.items;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("PATCH /api/tasks takes a ", str(parts[0], "text"));
    try testing.expect(!parts[0].object.get("hit").?.bool);
    try testing.expectEqualStrings("list", str(parts[1], "text"));
    try testing.expect(parts[1].object.get("hit").?.bool);
    try testing.expectEqualStrings(" of ids", str(parts[2], "text"));
    try testing.expectEqualStrings("1 / 3", str(got.root.object.get("filter").?, "count"));
    try testing.expectEqual(@as(i64, 1), got.root.object.get("closed_count").?.integer);
    try testing.expectEqualStrings("1 more closed with \"LIST\" in the title", str(got.root, "closed_title"));
    // The c at the end of the keys is about all of them, filter or not.
    try testing.expectEqualStrings("Show the 3 closed", str(got.root.object.get("hint_closed").?, "text"));
    try testing.expect(got.root.object.get("no_match").? == .null);

    // Shown, the closed ones are filtered too.
    in.closed = true;
    var shown = try rendered(in);
    defer shown.deinit();
    const closed = shown.root.object.get("closed").?.array.items;
    try testing.expectEqual(@as(usize, 1), closed.len);
    try testing.expectEqual(@as(i64, 213), closed[0].object.get("id").?.integer);
    const closed_parts = closed[0].object.get("title_parts").?.array.items;
    try testing.expectEqualStrings("List", str(closed_parts[0], "text"));
    try testing.expect(closed_parts[0].object.get("hit").?.bool);
}

test "2083: a title is cut at every hit, in whole characters, and Chinese is matched as it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Twice, at the ends.
    const ends = try titleParts(a, "ab-x-AB", "ab");
    try testing.expectEqual(@as(usize, 3), ends.len);
    try testing.expectEqualStrings("ab", ends[0].text);
    try testing.expect(ends[0].hit);
    try testing.expectEqualStrings("-x-", ends[1].text);
    try testing.expect(!ends[1].hit);
    try testing.expectEqualStrings("AB", ends[2].text);
    try testing.expect(ends[2].hit);
    // Chinese: the hit is whole characters, and so is what is around it.
    const zh = try titleParts(a, "给任务列表加批量编辑", "批量");
    try testing.expectEqual(@as(usize, 3), zh.len);
    try testing.expectEqualStrings("给任务列表加", zh[0].text);
    try testing.expectEqualStrings("批量", zh[1].text);
    try testing.expect(zh[1].hit);
    try testing.expectEqualStrings("编辑", zh[2].text);
    for (zh) |part| try testing.expect(std.unicode.utf8ValidateSlice(part.text));
    // Not in it: the title whole, unmarked.
    const none = try titleParts(a, "Multi-select", "zebra");
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expect(!none[0].hit);
}

test "2083: a filter nothing open has says so, and whether the closed ones have it" {
    var in = baseIn();
    // Only closed ones have "routes": said, with c to show them.
    in.filter = "routes";
    var hidden = try rendered(in);
    defer hidden.deinit();
    try testing.expectEqual(@as(usize, 0), hidden.root.object.get("open").?.array.items.len);
    const said = hidden.root.object.get("no_match").?;
    try testing.expectEqualStrings("No task has \"routes\" in its title", str(said, "title"));
    try testing.expectEqualStrings("1 closed ones have \"routes\" in the title; press c to show them. Press Esc to clear the filter.", str(said, "detail"));
    try testing.expectEqualStrings("0 / 3", str(hidden.root.object.get("filter").?, "count"));
    // Said there, so not said again on a row of its own.
    try testing.expect(hidden.root.object.get("closed_title").? == .null);
    try testing.expect(hidden.root.object.get("closed_key").? == .null);

    // Nothing anywhere: the closed ones were looked at too, and no row.
    in.filter = "zebra";
    var nothing = try rendered(in);
    defer nothing.deinit();
    try testing.expectEqualStrings("The closed ones were searched too. Press Esc to clear the filter.", str(nothing.root.object.get("no_match").?, "detail"));
    try testing.expect(nothing.root.object.get("closed_title").? == .null);
}

/// The complaint of task 2248, on the page itself: the number is in the
/// page's own first column, and typing it back found nothing. `wrote` is
/// what the person types; the two cells below are the two spellings.
fn theNumberFinds2149(wrote: []const u8) !void {
    const one = [_]Task{
        .{ .id = 2149, .title = "resource_overview says what Polter is using", .state = .open, .progress = .working, .owner = "core" },
    };
    var in = baseIn();
    in.tasks = &one;
    in.filter = wrote;
    var got = try rendered(in);
    defer got.deinit();
    const open = got.root.object.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqual(@as(i64, 2149), open[0].object.get("id").?.integer);
    try testing.expectEqualStrings("1 / 1", str(got.root.object.get("filter").?, "count"));
    // The number is not in the title, so nothing in it is marked: the title
    // is drawn as it is.
    const parts = open[0].object.get("title_parts").?.array.items;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expect(!parts[0].object.get("hit").?.bool);
    try testing.expect(got.root.object.get("no_match").? == .null);
}

test "2248: 2149 finds #2149" {
    try theNumberFinds2149("2149");
}

test "2248: #2149 finds #2149" {
    try theNumberFinds2149("#2149");
}

test "2248: a number no task has says so, and a closed one is found and counted" {
    var in = baseIn();
    in.filter = "#9999";
    var none = try rendered(in);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.root.object.get("open").?.array.items.len);
    try testing.expect(none.root.object.get("no_match").? != .null);

    // A closed one, by its number: found, counted, and folded away with the
    // rest until c.
    in.filter = "213";
    var shut = try rendered(in);
    defer shut.deinit();
    try testing.expectEqual(@as(usize, 0), shut.root.object.get("open").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), shut.root.object.get("closed_count").?.integer);

    // A title is matched by its letters, as it was, case ignored.
    in.filter = "MULTI";
    var by_title = try rendered(in);
    defer by_title.deinit();
    const found = by_title.root.object.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(i64, 214), found[0].object.get("id").?.integer);
}

test "2248: a number finds that task, and neither a longer one nor a padded one" {
    // **The digits as written.** #214 is a task of its own beside #2149, so a
    // rule that looked for the number inside the id would answer "214" with
    // two of them.
    try testing.expect(numberIs(2149, "2149"));
    try testing.expect(numberIs(2149, "#2149"));
    try testing.expect(!numberIs(2149, "214"));
    try testing.expect(!numberIs(2149, "21490"));
    try testing.expect(!numberIs(2149, "02149"));
    try testing.expect(!numberIs(2149, "2149 "));
    try testing.expect(!numberIs(2149, "#"));
    try testing.expect(!numberIs(2149, ""));

    const t: Task = .{ .id = 2149, .title = "Filter by number", .state = .open, .progress = .working, .owner = "" };
    try testing.expect(matches(t, "2149"));
    try testing.expect(matches(t, "#2149"));
    try testing.expect(matches(t, "filter"));
    try testing.expect(!matches(t, "214"));
    try testing.expect(!matches(t, "2150"));
    // An empty box is every task, as it was.
    try testing.expect(matches(t, ""));
}

test "2614: a legacy task with no squad and no worktree says nothing of either" {
    var in = baseIn();
    in.open_task = 215;
    var got = try rendered(in);
    defer got.deinit();

    const open_rows = got.root.object.get("open").?.array.items;
    try testing.expectEqualStrings("api", str(open_rows[1], "owner"));
    try testing.expect(open_rows[1].object.get("worktree") == null or open_rows[1].object.get("worktree").? == .null);

    const d = open_rows[1].object.get("detail").?.object;
    try testing.expect(d.get("squad") == null or d.get("squad").? == .null);
    try testing.expect(d.get("worktree") == null or d.get("worktree").? == .null);
    try testing.expect(d.get("tokens") == null or d.get("tokens").? == .null);
}

test "2614: the owner column is the squad's name, the seat carries its slot, and the tree its own path" {
    // A key and a name that differ, because they do in the real thing
    // (`wt-polter` against 「Polter核心开发小队」): a page that drew the key
    // would pass a test whose two were the same string.
    const seats = [_]TaskMember{
        .{ .alias = "审核", .role = "reviewer", .lead = true, .slot = "filled", .terminal = "0x361a", .cli = "claude" },
        .{ .alias = "开发", .role = "dev", .lead = false, .slot = "empty", .terminal = "—", .cli = "" },
        .{ .alias = "测试", .role = "tester", .lead = false, .slot = "vacated", .terminal = "—", .cli = "" },
    };
    const tok_slices = [_]TokenSlice{
        .{ .alias = "审核", .role = "reviewer", .tokens = "38.5k", .pct = 35, .color = "#3B82F6" },
        .{ .alias = "开发", .role = "dev", .tokens = "72.1k", .pct = 65, .color = "#10B981" },
    };
    const squad_tasks = [_]Task{
        .{
            .id = 2614,
            .title = "任务面板重构",
            .state = .open,
            .progress = .working,
            .owner = "0x361a",
            .squad = "wt-polter",
            .squad_name = "Polter核心开发小队",
            .worktree = "made",
            .worktree_path = "/src/proj-wt/polter/wt-2614",
            .members = &seats,
            .tokens = .{
                .total = "110.6k",
                .breakdown = &tok_slices,
            },
        },
    };

    var in = baseIn();
    in.group = "polter";
    in.tasks = &squad_tasks;
    in.open_task = 2614;
    var got = try rendered(in);
    defer got.deinit();

    const open_rows = got.root.object.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 1), open_rows.len);
    // The name, not the key.
    try testing.expectEqualStrings("Polter核心开发小队", str(open_rows[0], "owner"));
    // The row's tag is the branch the tree was made on.
    try testing.expectEqualStrings("wt/polter/2614", str(open_rows[0], "worktree"));

    const d = open_rows[0].object.get("detail").?.object;
    try testing.expectEqualStrings("Polter核心开发小队", str(d.get("squad").?, "name"));
    const seat_arr = d.get("squad").?.object.get("seats").?.array.items;
    try testing.expectEqual(@as(usize, 3), seat_arr.len);
    try testing.expectEqualStrings("审核", str(seat_arr[0], "alias"));
    try testing.expect(seat_arr[0].object.get("lead").?.bool);
    // **Three slots, three readings.** `empty` is a seat nobody has taken
    // and `vacated` one whose terminal has gone: a page told "filled" for
    // either would say a seat is being worked when it is not.
    try testing.expectEqualStrings("filled", str(seat_arr[0], "slot"));
    try testing.expectEqualStrings("empty", str(seat_arr[1], "slot"));
    try testing.expectEqualStrings("vacated", str(seat_arr[2], "slot"));

    const wt_obj = d.get("worktree").?.object;
    try testing.expectEqualStrings("wt/polter/2614", wt_obj.get("branch").?.string);
    // The ledger's path, not one spelled out of the task's number.
    try testing.expectEqualStrings("/src/proj-wt/polter/wt-2614", wt_obj.get("path").?.string);
    try testing.expectEqualStrings("made", wt_obj.get("state").?.string);

    try testing.expectEqualStrings("110.6k", d.get("tokens").?.object.get("total").?.string);
}

test "2614: a squad whose template is gone still reads as its key, and a planned tree has no path" {
    const seats = [_]TaskMember{
        .{ .alias = "审核", .role = "reviewer", .lead = true, .slot = "filled", .terminal = "0x361a", .cli = "claude" },
    };
    const gone = [_]Task{
        .{
            .id = 2614,
            .title = "任务面板重构",
            .state = .open,
            .progress = .working,
            .owner = "0x361a",
            // No `squad_name`: the app could not resolve the key.
            .squad = "wt-deleted",
            .worktree = "planned",
            .members = &seats,
        },
    };

    var in = baseIn();
    in.group = "polter";
    in.tasks = &gone;
    in.open_task = 2614;
    var got = try rendered(in);
    defer got.deinit();

    const open_rows = got.root.object.get("open").?.array.items;
    try testing.expectEqualStrings("wt-deleted", str(open_rows[0], "owner"));
    // A tree that is planned and not made: the tag names the branch it will
    // be made on, and there is no path yet because nothing is on disk.
    try testing.expectEqualStrings("wt/polter/2614", str(open_rows[0], "worktree"));

    const wt_obj = open_rows[0].object.get("detail").?.object.get("worktree").?.object;
    try testing.expectEqualStrings("planned", wt_obj.get("state").?.string);
    try testing.expectEqualStrings("", wt_obj.get("path").?.string);
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
