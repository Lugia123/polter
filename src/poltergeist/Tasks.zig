//! The panel: who is doing which piece of work, and how far along it is.
//!
//! **What this stores is "who is doing what", never "what the work is."**
//! A one-line title, the terminal responsible, open/closed/cancelled, a
//! progress word, and what kind of work it is. Nothing else, and the
//! shortness is the design rather than a stage it is passing through: see
//! `docs/poltergeist/tasks.md`, which rewrote half of principle P7 to allow
//! this much and drew the line at exactly this much. A requirement, a
//! dependency, an acceptance criterion, a due date, a comment -- **anything
//! a one-line title cannot hold belongs to another carrier**, and there are
//! better ones. Adding a field here means going back and changing that
//! chapter first.
//!
//! ⚠️ **`kind` was added on 2026-09-09 and the chapter was changed first**,
//! which is the procedure this paragraph asks for rather than an exception
//! to it. The argument for it is not "one more field would be useful": it is
//! that a supervisor sorting a night's panel was doing it by reading titles,
//! and **a convention written into a title is not something anything can
//! filter on** -- which is the same reason the panel exists at all rather
//! than the instruction living in a terminal's scrollback.
//!
//! The reason it exists at all is attention. A command typed into a
//! terminal with `terminal_send` scrolls off, gets compacted away, and by
//! three in the morning the worker no longer knows what it was set to do.
//! That is the same argument that killed work modes (P5): a state that only
//! exists at the moment it is set is not a state. This is that argument
//! applied to "what was I given to do".
//!
//! A task belongs to a **group**, not to the world. The conversations view
//! switches groups in the left-hand column and tabs between chat and tasks
//! on the right, and changing tab must not change which group you are
//! looking at.
//!
//! Pure, the same way `Chat` is: no clock, no filesystem, and the only
//! allocation is the registry. **Cancellation's "tell the worker first" is
//! deliberately not in here** -- telling somebody is a side effect, and the
//! model would have to reach a terminal to do it. The host does the telling
//! and then calls `cancel`, which is what makes the order enforceable.

const Tasks = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

pub const Id = Bus.Id;

/// A task's own number. Handed to agents, so it is small and readable.
pub const TaskId = u64;

/// Nobody is on it yet. Zero is the user's id in `Chat`, and a task can no
/// more be assigned to the person at the keyboard than a terminal can be,
/// so the value is free to mean "unassigned" here.
pub const nobody: Id = 0;

/// Where a task stands. Three, and there will not be a fourth: a state
/// machine with more arms in it is a task system, which is the thing this
/// chapter is not building.
pub const State = enum {
    /// Somebody is meant to be doing it.
    open,

    /// Done and checked off by the supervisor.
    closed,

    /// Called off before it was finished. The worker was told; see
    /// `docs/poltergeist/tasks.md`.
    cancelled,
};

/// How far along. **An enum and not free text**, and that is the red line
/// doing its job rather than a matter of taste: a free-text progress field
/// is a second description, and a second description is how a panel that
/// stores "who is doing what" turns into one that stores the work itself.
/// It also answers the thing the supervisor actually asks -- "is anybody
/// stuck" -- without anybody reading prose. The prose still exists; it goes
/// in the group, where it is read once and recorded, and the report says
/// which task it is about.
pub const Progress = enum {
    /// Assigned, not started.
    queued,

    /// Being worked on.
    working,

    /// Stopped and waiting on something. The one value worth a
    /// supervisor's attention on sight.
    blocked,

    /// The worker believes it is finished. Not the same as `closed`:
    /// closing is the supervisor's word, after it has checked.
    done,
};

/// What kind of work this is, for a supervisor sorting a night's panel.
///
/// **Five values, four of them choosable**, and the fifth is the whole
/// reason this is an enum rather than a word in the title.
pub const Kind = enum {
    feature,
    bug,
    research,

    /// **A tier, not a fallback.** Nothing lands here by omission -- the
    /// field is required at creation -- because a field with a default
    /// arrives at "everything is other" inside a fortnight, and then it
    /// sorts nothing.
    other,

    /// **Tasks made before this field existed**, restored from the record.
    /// Not choosable: `task_create` refuses it.
    ///
    /// ⚠️ **The point of it being its own value rather than `other`** is
    /// that the two facts are different and, folded together, can never be
    /// separated again: "somebody looked and said other" and "this predates
    /// the question". Kept apart, "show me everything older than the field"
    /// is a query rather than an excavation.
    unset,

    /// Whether a caller may ask for this one.
    pub fn choosable(self: Kind) bool {
        return self != .unset;
    }
};

pub const Task = struct {
    id: TaskId,

    /// Owned by the panel.
    group: []const u8,

    /// One line. Owned by the panel.
    title: []const u8,

    /// The terminal responsible, or `nobody`.
    ///
    /// One, not several. Two owners is no owner, and splitting a task in
    /// two costs one line.
    owner: Id = nobody,

    state: State = .open,
    progress: Progress = .queued,

    /// See `Kind`. Restored tasks that predate the field arrive as `unset`.
    kind: Kind = .unset,
};

pub const Config = struct {
    /// A title is a line, so it is bounded like one. Longer is cut rather
    /// than refused: the caller gets a short title, which is what was
    /// asked for anyway.
    max_title_bytes: usize = 160,

    /// A ceiling a caller may set. **The default is not one**, and that is
    /// the point rather than an oversight.
    ///
    /// It used to be 512, to stop a runaway supervisor filling memory with
    /// panels. What that reasoning missed is the other half of this file:
    /// `close` and `cancel` set a state and leave the row where it is,
    /// deliberately, because the panel is what somebody reads in the
    /// morning and a finished task is part of that. So the ceiling counted
    /// rows that never go away, and a panel that had done a lot of work
    /// stopped being able to record any more -- while the error told the
    /// caller to close what was finished, which is the one action that
    /// cannot help. Two decisions that were each right, and wrong together.
    ///
    /// ⚠️ The list is a single table for every group at once, so the count
    /// that ran out was not any one panel's. It ran out at 360 rows in the
    /// group that hit it.
    ///
    /// The mechanism stays because a caller with a reason can still ask for
    /// a limit, and the test below holds that path open.
    max_tasks: usize = std.math.maxInt(usize),
};

pub const Error = error{
    NoSuchTask,
    TooManyTasks,

    /// Nothing but whitespace where a title should be.
    BadTitle,

    /// A kind that is not one a caller may ask for -- see `Kind.unset`.
    BadKind,

    /// A worker reaching for a task that is not its own.
    NotYours,

    /// The task is closed or cancelled, so there is nothing to move.
    NotOpen,
} || Allocator.Error;

alloc: Allocator,
config: Config,

/// In creation order, which is the order the panel reads in.
list: std.ArrayListUnmanaged(Task) = .empty,

/// The next number to hand out. Never reused: a number that came back
/// round would tie a worker's progress report to somebody else's work.
next_id: TaskId = 1,

pub fn init(alloc: Allocator, config: Config) Tasks {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Tasks) void {
    for (self.list.items) |t| {
        self.alloc.free(t.group);
        self.alloc.free(t.title);
    }
    self.list.deinit(self.alloc);
    self.* = undefined;
}

/// Make a task in a group. Nobody is on it until it is assigned.
pub fn create(
    self: *Tasks,
    group: []const u8,
    title: []const u8,
    kind: Kind,
) Error!TaskId {
    // **Refused rather than silently filed.** `unset` means "made before
    // there was a question"; letting a caller ask for it would put new
    // tasks in with the old ones and make the one query this field is for
    // -- what predates it -- unanswerable for good.
    if (!kind.choosable()) return error.BadKind;

    const id = self.next_id;
    try self.put(id, group, title);
    self.list.items[self.list.items.len - 1].kind = kind;
    self.next_id = id + 1;
    return id;
}

/// Change a task's title.
///
/// **The panel is a written record, so this leaves a trail** -- the caller
/// is `TaskLog`'s to record as `edited`, the same way assigning is. What
/// makes it worth having at all: a title that turned out to be wrong used
/// to be uncorrectable, so a sentence that had stopped being true stayed on
/// the panel misleading everybody who read it. Cancelling and re-creating
/// was the only way, and it changes the number every earlier message refers
/// to.
///
/// ⚠️ **What it cannot fix**: messages already sent quoting the old title.
/// `task_history` is where those are reconciled, and that is the cost of
/// this being editable at all.
pub fn setTitle(self: *Tasks, id: TaskId, title: []const u8) Error!void {
    const t = try self.find(id);
    const kept = try self.oneLine(title);
    errdefer self.alloc.free(kept);
    self.alloc.free(t.title);
    t.title = kept;
}

/// Change a task's kind. `unset` is refused here for the reason it is
/// refused in `create`.
pub fn setKind(self: *Tasks, id: TaskId, kind: Kind) Error!void {
    if (!kind.choosable()) return error.BadKind;
    const t = try self.find(id);
    t.kind = kind;
}

/// Put a task back with the number it already had.
///
/// For replaying the record after a restart, and for nothing else. The
/// counter is dragged past whatever comes back so the next fresh task
/// cannot land on a number the record already used.
pub fn restore(self: *Tasks, task: Task) Error!void {
    try self.put(task.id, task.group, task.title);
    const t = &self.list.items[self.list.items.len - 1];
    t.owner = task.owner;
    t.state = task.state;
    t.progress = task.progress;
    t.kind = task.kind;
    if (task.id >= self.next_id) self.next_id = task.id + 1;
}

/// A title, trimmed to the one line the panel can draw, owned by the panel.
///
/// **Shared by `put` and `setTitle` rather than written twice.** A second
/// copy of "what a title is allowed to be" is how a title set one way comes
/// to differ from a title set the other, and the panel draws them the same.
fn oneLine(self: *Tasks, title: []const u8) Error![]u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed.len == 0) return error.BadTitle;

    // A title is one line by construction, not by asking politely: a
    // newline in it would draw as two rows in the panel and the second one
    // would look like a task with no state.
    const one_line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    const kept = utf8Cut(std.mem.trim(u8, one_line, " \t\r"), self.config.max_title_bytes);
    if (kept.len == 0) return error.BadTitle;
    return self.alloc.dupe(u8, kept);
}

fn put(self: *Tasks, id: TaskId, group: []const u8, title: []const u8) Error!void {
    if (self.list.items.len >= self.config.max_tasks) return error.TooManyTasks;

    const owned_title = try self.oneLine(title);
    errdefer self.alloc.free(owned_title);
    const owned_group = try self.alloc.dupe(u8, group);
    errdefer self.alloc.free(owned_group);

    try self.list.append(self.alloc, .{
        .id = id,
        .group = owned_group,
        .title = owned_title,
    });
}

fn find(self: *Tasks, id: TaskId) Error!*Task {
    for (self.list.items) |*t| {
        if (t.id == id) return t;
    }
    return error.NoSuchTask;
}

pub fn get(self: *const Tasks, id: TaskId) ?Task {
    for (self.list.items) |t| {
        if (t.id == id) return t;
    }
    return null;
}

/// Hand a task to a terminal. Also the way to take it back, with `nobody`.
pub fn assign(self: *Tasks, id: TaskId, owner: Id) Error!void {
    const t = try self.find(id);
    if (t.state != .open) return error.NotOpen;
    t.owner = owner;
}

/// The supervisor has checked the work and is done with it.
pub fn close(self: *Tasks, id: TaskId) Error!void {
    const t = try self.find(id);
    t.state = .closed;
}

/// Called off. **The worker must already have been told.**
///
/// Nothing here can enforce that, which is why it is written here: the
/// host tells the worker and only then calls this, and a cancellation the
/// worker was not told about is the silent state change this whole
/// repository has shipped three times already.
pub fn cancel(self: *Tasks, id: TaskId) Error!void {
    const t = try self.find(id);
    t.state = .cancelled;
}

/// A worker moving its own task along.
///
/// Refused for somebody else's, and refused once the task is shut: a
/// progress report on a cancelled task is the worker saying it did not get
/// the message, and answering `ok` would be the second half of the same
/// mistake.
pub fn setProgress(
    self: *Tasks,
    id: TaskId,
    by: Id,
    progress: Progress,
) Error!void {
    const t = try self.find(id);
    if (t.owner != by) return error.NotYours;
    if (t.state != .open) return error.NotOpen;
    t.progress = progress;
}

/// Forget a terminal's ownership everywhere, because it closed.
///
/// The tasks stay. What was being worked on last night is exactly what the
/// morning wants to see, and a task whose owner has gone is a task that
/// needs somebody -- which is visible only if it is still there.
pub fn forget(self: *Tasks, id: Id) void {
    for (self.list.items) |*t| {
        if (t.owner == id) t.owner = nobody;
    }
}

/// Drop a group's tasks, because the group is gone.
pub fn forgetGroup(self: *Tasks, group: []const u8) void {
    var i: usize = 0;
    while (i < self.list.items.len) {
        if (std.mem.eql(u8, self.list.items[i].group, group)) {
            const t = self.list.orderedRemove(i);
            self.alloc.free(t.group);
            self.alloc.free(t.title);
            continue;
        }
        i += 1;
    }
}

// -- the two views, which are two functions on purpose ----------------------
//
// The person at the keyboard and a worker are not asking the same question,
// and one filter with a flag through it would make them look as though they
// were. The user is looking back over a night: closed and cancelled work is
// most of what they want to see, because that is the record of what
// happened. A worker is looking at what it is meant to be doing right now:
// anything closed, cancelled, or somebody else's is not merely irrelevant
// to it, it is the noise this whole panel exists to remove.

/// Everything in a group, in the order it was made. What the panel draws,
/// and what a supervisor checking the night's work reads.
pub fn inGroup(
    self: *const Tasks,
    alloc: Allocator,
    group: []const u8,
) Allocator.Error![]const Task {
    var out: std.ArrayListUnmanaged(Task) = .empty;
    errdefer out.deinit(alloc);

    for (self.list.items) |t| {
        if (!std.mem.eql(u8, t.group, group)) continue;
        try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

/// What one worker is meant to be doing: its own, still open.
pub fn forWorker(
    self: *const Tasks,
    alloc: Allocator,
    group: []const u8,
    owner: Id,
) Allocator.Error![]const Task {
    var out: std.ArrayListUnmanaged(Task) = .empty;
    errdefer out.deinit(alloc);

    // Never `nobody`: an unassigned task is not "everybody's", and a
    // worker asking with no id must not be handed the unclaimed pile.
    if (owner == nobody) return out.toOwnedSlice(alloc);

    for (self.list.items) |t| {
        if (!std.mem.eql(u8, t.group, group)) continue;
        if (t.owner != owner) continue;
        if (t.state != .open) continue;
        try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

/// `text` cut to at most `limit` bytes without splitting a character.
///
/// The same reasoning as `Chat.utf8Cut`, and for the same consequence: the
/// JSON writer answers invalid UTF-8 with an array of numbers, so a title
/// cut through the middle of a Chinese character comes back to the reader
/// as a list of byte values instead of a string.
fn utf8Cut(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var i = limit;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return text[0..i];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const worker_a: Id = 0x2222;
const worker_b: Id = 0x3333;

fn testTasks() Tasks {
    return .init(testing.allocator, .{});
}

test "a task starts open, unassigned and queued" {
    var t = testTasks();
    defer t.deinit();

    const id = try t.create("build", "get the core building again", .bug);
    const got = t.get(id).?;
    try testing.expectEqual(State.open, got.state);
    try testing.expectEqual(Progress.queued, got.progress);
    try testing.expectEqual(nobody, got.owner);
    try testing.expectEqualStrings("build", got.group);
}

test "numbers are never reused" {
    var t = testTasks();
    defer t.deinit();

    const first = try t.create("build", "one", .research);
    try t.close(first);
    const second = try t.create("build", "two", .other);
    try testing.expect(second != first);
}

test "a title is one line and bounded" {
    var t = testTasks();
    defer t.deinit();

    try testing.expectError(error.BadTitle, t.create("build", "   \n  ", .feature));

    const id = try t.create("build", "the headline\nand a paragraph nobody asked for", .bug);
    try testing.expectEqualStrings("the headline", t.get(id).?.title);

    var long: [400]u8 = @splat('x');
    const wide = try t.create("build", &long, .other);
    try testing.expect(t.get(wide).?.title.len <= 160);
}

test "a title is not cut through the middle of a character" {
    var t: Tasks = .init(testing.allocator, .{ .max_title_bytes = 4 });
    defer t.deinit();

    const id = try t.create("build", "日日", .research);
    // Three bytes each: one whole character fits, and the second must not
    // be handed over in pieces.
    try testing.expectEqualStrings("日", t.get(id).?.title);
}

test "a worker may move its own task and nobody else's" {
    var t = testTasks();
    defer t.deinit();

    const id = try t.create("build", "one", .other);
    try t.assign(id, worker_a);

    try t.setProgress(id, worker_a, .working);
    try testing.expectEqual(Progress.working, t.get(id).?.progress);

    try testing.expectError(error.NotYours, t.setProgress(id, worker_b, .done));
    try testing.expectEqual(Progress.working, t.get(id).?.progress);
}

test "progress on a task that is over is refused" {
    var t = testTasks();
    defer t.deinit();

    const id = try t.create("build", "one", .feature);
    try t.assign(id, worker_a);
    try t.cancel(id);

    // The worker still thinks it is working, which is precisely the state
    // an `ok` here would confirm for it.
    try testing.expectError(error.NotOpen, t.setProgress(id, worker_a, .working));
}

test "a worker sees its own open tasks and nothing else" {
    var t = testTasks();
    defer t.deinit();

    const mine = try t.create("build", "mine", .bug);
    try t.assign(mine, worker_a);

    const theirs = try t.create("build", "theirs", .research);
    try t.assign(theirs, worker_b);

    const shut = try t.create("build", "shut", .other);
    try t.assign(shut, worker_a);
    try t.close(shut);

    const called_off = try t.create("build", "called off", .feature);
    try t.assign(called_off, worker_a);
    try t.cancel(called_off);

    _ = try t.create("build", "unclaimed", .bug);

    const seen = try t.forWorker(testing.allocator, "build", worker_a);
    defer testing.allocator.free(seen);

    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqual(mine, seen[0].id);
}

test "the panel keeps what a worker is spared" {
    // The two filters disagreeing is the point of there being two.
    var t = testTasks();
    defer t.deinit();

    const shut = try t.create("build", "shut", .research);
    try t.assign(shut, worker_a);
    try t.close(shut);

    const theirs = try t.create("build", "theirs", .other);
    try t.assign(theirs, worker_b);

    const seen = try t.inGroup(testing.allocator, "build");
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 2), seen.len);

    const worker = try t.forWorker(testing.allocator, "build", worker_a);
    defer testing.allocator.free(worker);
    try testing.expectEqual(@as(usize, 0), worker.len);
}

test "an unassigned task is nobody's, not everybody's" {
    var t = testTasks();
    defer t.deinit();

    _ = try t.create("build", "unclaimed", .feature);

    const seen = try t.forWorker(testing.allocator, "build", nobody);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);
}

test "tasks belong to a group, so another group's are not shown" {
    var t = testTasks();
    defer t.deinit();

    const here = try t.create("build", "here", .bug);
    try t.assign(here, worker_a);
    const there = try t.create("ops", "there", .research);
    try t.assign(there, worker_a);

    const seen = try t.forWorker(testing.allocator, "build", worker_a);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqual(here, seen[0].id);
}

test "a terminal closing leaves the work behind, without an owner" {
    var t = testTasks();
    defer t.deinit();

    const id = try t.create("build", "one", .other);
    try t.assign(id, worker_a);
    t.forget(worker_a);

    try testing.expectEqual(nobody, t.get(id).?.owner);
    try testing.expectEqual(State.open, t.get(id).?.state);
}

test "a group going takes its tasks with it" {
    var t = testTasks();
    defer t.deinit();

    _ = try t.create("build", "one", .feature);
    _ = try t.create("ops", "two", .bug);
    t.forgetGroup("build");

    const left = try t.inGroup(testing.allocator, "build");
    defer testing.allocator.free(left);
    try testing.expectEqual(@as(usize, 0), left.len);

    const other = try t.inGroup(testing.allocator, "ops");
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(usize, 1), other.len);
}

test "a restored task keeps its number and pushes the counter past it" {
    var t = testTasks();
    defer t.deinit();

    try t.restore(.{
        .id = 40,
        .group = "build",
        .title = "from last night",
        .owner = worker_a,
        .state = .open,
        .progress = .working,
    });

    const got = t.get(40).?;
    try testing.expectEqual(worker_a, got.owner);
    try testing.expectEqual(Progress.working, got.progress);

    try testing.expectEqual(@as(TaskId, 41), try t.create("build", "fresh", .research));
}

test "the panel refuses to grow without limit" {
    var t: Tasks = .init(testing.allocator, .{ .max_tasks = 2 });
    defer t.deinit();

    _ = try t.create("build", "one", .other);
    _ = try t.create("build", "two", .feature);
    try testing.expectError(error.TooManyTasks, t.create("build", "three", .bug));
}

test "closing a task does not free its row, so the default must not be a ceiling" {
    // **The two halves of this were each right and together they were a
    // trap.** Closed tasks stay on the panel on purpose -- the person
    // reading it in the morning wants to see what was finished -- and
    // `close` therefore only sets a state, leaving the row where it was.
    // With a ceiling counted against rows, a panel that had done a lot of
    // work stopped being able to record any more, and the error told the
    // caller to close what was finished, which is the one action that
    // cannot help. It happened at 360 rows in one group; the list is one
    // table for every group at once, so the rest came from elsewhere and
    // "this panel is full" was wrong about which panel, too.
    var t: Tasks = .init(testing.allocator, .{});
    defer t.deinit();

    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const id = try t.create("build", "a line", .other);
        try t.close(id);
    }
    try testing.expectEqual(@as(usize, 600), t.list.items.len);

    // And one more after all of those, which is the case that failed.
    _ = try t.create("build", "the six hundred and first", .other);
}

test "a task that is not there is not a task" {
    var t = testTasks();
    defer t.deinit();

    try testing.expectError(error.NoSuchTask, t.close(7));
    try testing.expectError(error.NoSuchTask, t.cancel(7));
    try testing.expectError(error.NoSuchTask, t.assign(7, worker_a));
    try testing.expectError(error.NoSuchTask, t.setProgress(7, worker_a, .done));
    try testing.expect(t.get(7) == null);
}

test "the panel stores what the chapter says it stores and no more" {
    // The red line, made mechanical. A field added here without going back
    // to `docs/poltergeist/tasks.md` fails this, which is the only form of
    // "do not let it grow into a task system" that outlives whoever wrote
    // the sentence.
    const names = comptime blk: {
        var out: []const []const u8 = &.{};
        for (@typeInfo(Task).@"struct".fields) |f| out = out ++ [_][]const u8{f.name};
        break :blk out;
    };

    // ⚠️ **`kind` was added on 2026-09-09, and the chapter was changed
    // first** -- which is the whole procedure this test exists to force. It
    // is written here as well as there because this list is what somebody
    // edits when they want a seventh field, and the sentence they need to
    // read is "go and change the chapter", not "add a string".
    //
    // What the chapter now says, in one line: the panel stores **who is
    // doing which piece of work, how far along it is, and what kind of work
    // it is** -- because a supervisor sorting a night's panel was doing it
    // by reading titles, and a convention written into titles is not
    // something anything can filter on.
    const allowed = [_][]const u8{ "id", "group", "title", "owner", "state", "progress", "kind" };
    try testing.expectEqual(allowed.len, names.len);
    for (names) |n| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, n)) ok = true;
        }
        if (!ok) {
            std.debug.print("\nTask gained a field: {s}\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
}
